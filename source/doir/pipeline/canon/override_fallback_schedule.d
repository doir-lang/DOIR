/// `opt.findFallbackScheduleOverride`: the first half of
/// `compiler.override_fallback_schedule("...")`, which replaces the schedule the
/// compiler lowers the whole module with.
///
/// `compiler.run_schedule` is the local form of the same idea - it runs its
/// schedule then and there, over the block the call sits in. That is no use to
/// a backend, which does not want to be run at the point it was declared: it
/// wants to be what "lowering" *means* for this compile, including inside the
/// throwaway blocks `opt.comptimeEvaluate` builds and lowers one per comptime
/// call. So this builtin does not run anything. It nominates, and
/// `doir.pipeline.runFallbackSchedule` runs whatever was nominated - twice over,
/// in general, since comptime evaluation lowers with it long before the final
/// lowering does.
///
/// Which nomination wins is the whole reason this is two passes rather than
/// one. `early_include` splices a file's contents into the block that included
/// it, so a program and every backend underneath it end up nominating from the
/// same block, in include order: the deepest include first, the includer's own
/// line last. The rule that falls out of that is "outermost, then bottom most":
///
/// - Outermost - the shallowest block - so a nomination made inside a nested
///   block (a function body, a quoted block) cannot speak for the module.
/// - Bottom most among those, so the file that included a backend overrides the
///   backend it included, rather than the other way round.
///
/// Neither is knowable until the walk has seen every call, which is why the
/// running is a separate pass afterwards.
module doir.pipeline.canon.override_fallback_schedule;

import ecrs.storage : EntityId, invalidEntity;

static import fp.dynarray;
import fp.dynarray : daLength = length;

import doir.diagnostics;
import doir.dynamic_systems : DynamicSystem, freeSystem, parseSystem, reportSystemError;
import doir.interface_;
import doir.module_;
import doir.systems : beginLoweringSchedule, endLoweringSchedule;
// The fallback, and the only edge in here that points back up at the pipeline.
// `doir.pipeline` imports this module in turn - as it does `opt.run_schedule`,
// through `doir.dynamic_systems`' registry - which D resolves without help.
import doir.pipeline : mizuSchedule;

@nogc nothrow:


/// The standing nomination: the schedule to lower with, already parsed, plus
/// how deep the call that nominated it sat. Thread-local, like
/// `doir.pipeline.canon.sort.newRoot`.
private struct Nomination {
	bool found;
	/// Block nesting depth of the winning call. `size_t.max` while there is
	/// none, so the first candidate at any depth beats it.
	size_t depth = size_t.max;
	DynamicSystem system;
	/// The schedule as the source wrote it, interned, so that a block which
	/// claimed this same schedule can recognize it as the one already running.
	/// See `doir.systems.isCurrentSchedule`.
	const(char)[] source;
}

private Nomination nomination;

/// Whether anything has nominated a schedule since `clearFallbackScheduleOverride`.
bool hasFallbackScheduleOverride() { return nomination.found; }

/// Drops the standing nomination. A schedule calls this before the walk that
/// may make one, so a previous compile in the same process cannot lower this
/// one.
void clearFallbackScheduleOverride() @trusted {
	if (nomination.found) freeSystem(nomination.system);
	nomination = Nomination.init;
}

/// Runs the nominated schedule over the whole module. Answers `true` when
/// there is none - "nobody asked for anything" is not a failure; picking what
/// to run instead is `doir.pipeline.runFallbackSchedule`'s job.
bool runFallbackScheduleOverride(ref Module mod) @trusted {
	if (!nomination.found) return true;
	// Named while it runs, so `doir.systems`' filter can tell that a block which
	// claimed this very schedule is not a second schedule to carve out.
	const previousSchedule = beginLoweringSchedule(nomination.source);
	scope(exit) endLoweringSchedule(previousSchedule);
	// Left at its default `currentCanonicalizeRoot`, so the walks inside it
	// resolve to whatever `canonicalize.sort` last produced - which is the
	// comptime block while `opt.comptimeEvaluate` is lowering one, and the
	// module root the rest of the time.
	return nomination.system(mod);
}

/// Block nesting depth of `e`: how many blocks it sits inside.
private size_t depthOf(ref Module mod, EntityId e) {
	size_t depth = 0;
	while (e != invalidEntity) {
		immutable parent = findParent(mod, e);
		if (parent == invalidEntity || parent == e) break; // the root contains itself
		e = parent;
		++depth;
	}
	return depth;
}

/// Pass one: records the schedule `subtree` nominates if it beats the standing
/// nomination, and replaces the call with the length of the schedule string -
/// the same bargain `early_include` strikes, where the value is a byproduct and
/// the point is what the call did on its way to it.
///
/// The count is the string's length rather than "did this one win", because
/// whether it won is not settled until the walk ends and a call is replaced
/// while the walk is still going.
bool findFallbackScheduleOverride(ref Module mod, EntityId subtree) @trusted {
	if (!hasComponent!Call(mod, subtree)) return true;

	immutable overrideE = resolveCached(mod, "compiler.override_fallback_schedule", 1);
	if (overrideE == invalidEntity) return true;
	if (resolveAlias(mod, getComponent!Call(mod, subtree).related[0]) != overrideE)
		return true;

	if (!hasComponent!FunctionInputs(mod, subtree)) {
		expectsXInputs(mod, subtree, "override_fallback_schedule", "one");
		return false;
	}
	auto inputs = resolvedInputs(mod, subtree);
	scope(exit) fp.dynarray.free(inputs);
	if (daLength(inputs) != 1) {
		expectsXInputs(mod, subtree, "override_fallback_schedule", "one");
		return false;
	}

	if (!hasComponent!DString(mod, inputs[0])) {
		parameterError(mod, subtree, "override_fallback_schedule", 0,
			" must evaluate to a string constant");
		return false;
	}
	// Interned, and on a different entity to the one emptied out below, so it
	// outlives everything this function does to the call.
	auto source = getComponent!DString(mod, inputs[0]).value.view;

	immutable depth = depthOf(mod, subtree);

	// Stop being a call either way. The fallback schedule runs over this very
	// block later, and a `compiler.*` call nothing computes is one more thing
	// for every later pass to walk past.
	removeComponent!Call(mod, subtree);
	removeComponent!FunctionInputs(mod, subtree);
	removeComponent!TypeOf(mod, subtree);
	attachNumber(mod, subtree, resolveCached(mod, "compiler.pointer_sized", 1), source.length);

	// Deeper than the standing nomination: a nested block does not get to speak
	// for the module. Equal depth replaces it, which is what makes the last
	// call in a block - the includer's own, after everything it included - the
	// one that stands.
	if (depth > nomination.depth) return true;

	auto system = parseSystem(source);
	if (!system.valid()) {
		// Pointed into the schedule string itself, at the text that did not
		// parse - `inputs[0]` is that string, `subtree` only the call it was
		// handed to.
		reportSystemError(mod, system, source, inputs[0], "override_fallback_schedule");
		freeSystem(system);
		return false;
	}

	if (nomination.found) freeSystem(nomination.system);
	nomination.found = true;
	nomination.depth = depth;
	nomination.system = system;
	nomination.source = source;
	return true;
}

/// Pass two of `compiler.override_fallback_schedule`: lowers the module with
/// whatever `findFallbackScheduleOverride` settled on, or with `mizuSchedule` if
/// nothing did.
///
/// Called twice over, in general - once per block `comptimeEvaluate` lowers, and
/// once at the end of `canonicalizeSchedule` for the module itself - because "how this
/// module is lowered" is one answer, and a block that runs at compile time is
/// lowered by it too.
bool runFallbackSchedule(ref Module mod) {
	if (hasFallbackScheduleOverride())
		return runFallbackScheduleOverride(mod);
	// Named as the running schedule even though it has no source text to name:
	// what matters to `doir.systems`' filter is that a lowering is in progress
	// at all, since outside one the filter is off. A null source matches no
	// claim, which is right - the compiler's own schedule is not the schedule
	// any block asked for.
	const previousSchedule = beginLoweringSchedule(null);
	scope(exit) endLoweringSchedule(previousSchedule);
	return mizuSchedule(mod);
}


// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest) {
	import tests.pipeline_helper;
}

unittest {
	// The whole point: a schedule written as a string becomes what lowering
	// means for this module, and the call is gone afterwards - replaced by how
	// long the string was.
	auto r = compile(
		"schedule : compiler.byte_pointer = \"depthFirst(pinRegisters)\"\n"
		~ "n : compiler.pointer_sized = compiler.override_fallback_schedule(schedule)\n");
	scope(exit) freeModule(r.mod);
	assert(r.ok);

	immutable n = find(r.mod, r.root, "n");
	assert(n != invalidEntity);
	assert(!hasComponent!Call(r.mod, n));
	assert(hasComponent!Number(r.mod, n));
	assert(getComponent!Number(r.mod, n).value == "depthFirst(pinRegisters)".length);
	clearFallbackScheduleOverride();
}

unittest {
	// Bottom most wins at equal depth, which is what makes a file override the
	// backend it included: the included file's nomination is spliced in above
	// the includer's own line. Only the second schedule here parses, so the
	// first standing would be a parse error rather than a silent difference.
	auto r = compile(
		"a : compiler.byte_pointer = \"depthFirst(no_such_pass)\"\n"
		~ "b : compiler.byte_pointer = \"depthFirst(pinRegisters)\"\n"
		~ "_ : compiler.pointer_sized = compiler.override_fallback_schedule(b)\n");
	scope(exit) freeModule(r.mod);
	assert(r.ok);
	assert(hasFallbackScheduleOverride());
	clearFallbackScheduleOverride();
}

unittest {
	// ...and outermost beats bottom most: a nomination made inside a nested
	// block cannot speak for the module, however far down it sits.
	clearFallbackScheduleOverride();
	auto r = compile(
		"outer : compiler.byte_pointer = \"depthFirst(pinRegisters)\"\n"
		~ "_ : compiler.pointer_sized = compiler.override_fallback_schedule(outer)\n"
		~ "blk : block = {\n"
		~ "\tinner : compiler.byte_pointer = \"depthFirst(no_such_pass)\"\n"
		~ "\t_ : compiler.pointer_sized = compiler.override_fallback_schedule(inner)\n"
		~ "}\n");
	scope(exit) freeModule(r.mod);
	// The nested call is still replaced - it just loses. A losing nomination is
	// never parsed, so the unparsable one inside the block costs nothing.
	assert(r.ok);
	assert(hasFallbackScheduleOverride());
	clearFallbackScheduleOverride();
}

unittest {
	// A schedule that does not parse is a diagnostic on the call, not a
	// half-run compile.
	auto r = compile(
		"schedule : compiler.byte_pointer = \"depthFirst(no_such_pass)\"\n"
		~ "_ : compiler.pointer_sized = compiler.override_fallback_schedule(schedule)\n");
	scope(exit) freeModule(r.mod);
	assert(!r.ok);
	assert(diagnostics().hasErrors());
	diagnostics().clear();
	clearFallbackScheduleOverride();
}

unittest {
	// The argument has to be a string the compiler can read *now*, the same
	// constraint `early_include` puts on its path.
	auto r = compile(
		"x : compiler.pointer_sized = 5\n"
		~ "_ : compiler.pointer_sized = compiler.override_fallback_schedule(x)\n");
	scope(exit) freeModule(r.mod);
	assert(!r.ok);
	assert(diagnostics().hasErrors());
	diagnostics().clear();
	clearFallbackScheduleOverride();
}

unittest {
	// A module that nominates nothing is left alone - the pass is scheduled
	// over every entity of every compile, so saying nothing is the common case,
	// and `runFallbackSchedule` falls back on the compiler's own.
	clearFallbackScheduleOverride();
	auto r = compile("n : compiler.pointer_sized = 5\n");
	scope(exit) freeModule(r.mod);
	assert(r.ok);
	assert(!hasFallbackScheduleOverride());
	assert(findFallbackScheduleOverride(r.mod, find(r.mod, r.root, "n")));
	assert(runFallbackScheduleOverride(r.mod)); // nothing nominated, nothing run
	assert(runFallbackSchedule(r.mod));
	assert(!diagnostics().hasErrors());
}
