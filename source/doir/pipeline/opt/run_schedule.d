/// `compiler.run_schedule("...")`: a block saying how the code that belongs to
/// it is lowered.
///
/// Two passes, because the answer to "who does this entity belong to?" has to
/// be the same throughout. `runSchedule` finds the calls and registers each
/// block's schedule without running any of them; `runRegisteredSchedules` then
/// runs them, one block at a time, each over the whole module with everything
/// owned by somebody else filtered out (see `doir.systems`' ownership section).
/// Registering as we go and running as we go would mean the first block's
/// schedule ran before the second block had claimed anything, and saw the
/// second block's code as unowned.
///
/// What "belongs" means is wider than "is inside": a block that declares
/// instructions owns every call to them, wherever that call was written. A
/// schedule that only reached the block itself would lower the declarations and
/// leave every use of them to whatever the module's fallback schedule happened to
/// be, which is the opposite of the point.
///
/// The other half of the pair is `compiler.override_fallback_schedule`, which
/// takes the same string and makes it what lowering means for the whole module.
/// This one is the local form: it is for a block that wants its own code done a
/// particular way, not for a backend declaring how everything is compiled.
///
/// Every other `compiler.*` builtin is computed by
/// `opt.computeCompilerNamespace`, and this one started there too. It is a pass
/// of its own for two reasons.
///
/// The first is when it runs. `computeCompilerNamespace` is scheduled twice by
/// the fallback schedule, which is itself run once per block the comptime
/// evaluator lowers - so a builtin computed there is visited many times over a
/// compile, which is fine for folding a constant and is not fine for running a
/// schedule. As its own pass it is scheduled once, in the one place where the
/// tree is resolved and evaluated but not yet lowered, which is the only point
/// at which a user's schedule can see what the lowering is about to do.
///
/// The second is what it depends on. `doir.dynamic_systems` enumerates the
/// pass modules to build its registry, so a pass that reaches into it is
/// reached back into; keeping that edge on a leaf module, rather than on the
/// one every `compiler.*` call goes through, is what stops the cycle from
/// running through the middle of the compiler.
module doir.pipeline.opt.run_schedule;

import diagnose.diagnostics : Ansi;
import ecrs.storage : EntityId, invalidEntity;

import ecrs.context : entities;

static import fp.dynarray;
import fp.dynarray : daLength = length;

import doir.diagnostics;
import doir.dynamic_systems : freeSystem, parseSystem, reportSystemError;
import doir.interface_;
import doir.interface_ : currentCanonicalizeRoot;
import doir.module_;
import doir.string_helpers : text;
static import ecrs.system;

import doir.systems : beginLoweringBlock, beginLoweringSchedule, endLoweringBlock, endLoweringSchedule, isCurrentSchedule, visitor;

@nogc nothrow:


/// The schedules running right now, by the identity of their interned source.
///
/// Keyed by the interned pointer rather than by the claiming block: a schedule
/// may `sort`, and a sort renumbers every entity, so an entity id saved across
/// a run belongs to somebody else by the time it returns. Nothing about an
/// entity survives a sort; the interned source pointer does, and it is what
/// `doir.systems.isCurrentSchedule` already identifies a schedule by.
private const(char)** runningSchedules;

/// Ditto - identity, not a comparison of the text, since the source is interned.
private bool isScheduleRunning(const(char)[] source) @trusted {
	foreach (i; 0 .. daLength(runningSchedules))
		if (runningSchedules[i] is source.ptr) return true;
	return false;
}

/// Runs `blockEntity`'s claimed schedule, if it has one it has not used yet,
/// over the whole module with the walkers filtered to what it owns.
/// `runRegisteredSchedules` is the spellable half.
///
/// Private, and deliberately: every public pass-shaped symbol in this module is
/// enumerated into `doir.dynamic_systems`' registry, and a schedule string
/// naming this one inside a walker would get a walk that visits nothing. A
/// claimed block is owned - by itself - so the walkers skip it while no block
/// is being lowered, which is exactly when this would be looking for claims.
private bool runRegisteredSchedule(ref Module mod, EntityId blockEntity) @trusted {
	if (!hasComponent!ScheduleClaim(mod, blockEntity)) return true;

	// Already being lowered by exactly this schedule - the ordinary case for a
	// backend, which says the same list twice: here, so the block owns the
	// calls to its declarations, and `compiler.override_fallback_schedule` so
	// the module is lowered that way too. Running it again would lower this
	// block's code a second time, and `opt.allocateRegisters` re-run over code
	// it has already pinned pins the pins. `doir.systems`' filter has the other
	// half of this: it does not carve out a block whose claim is the running
	// schedule, so standing down here leaves the code lowered, not skipped.
	if (isCurrentSchedule(getComponent!ScheduleClaim(mod, blockEntity).source.view))
		return true;

	// Re-entrancy, not once-per-compile. A claimed schedule may name
	// `runRegisteredSchedules` - mizu.doir's does - and that would find this
	// claim again and not stop, so the schedule is marked as running for the
	// duration of the run and unmarked again afterwards.
	//
	// Afterwards, and not left standing: `runFallbackSchedule` is run once per
	// tree that gets lowered - one per throwaway block `opt.comptimeEvaluate`
	// builds, then once for the module itself - and each of those is a
	// different tree, which this block has not lowered yet. A mark that stayed
	// put meant the first comptime call in the compile spent the claim, and
	// the module's own lowering then skipped it - leaving every call to this
	// block's declarations lowered by nobody, since the fallback schedule skips
	// what somebody has claimed.
	const(char)[] source = getComponent!ScheduleClaim(mod, blockEntity).source.view;
	if (isScheduleRunning(source)) return true;
	fp.dynarray.pushBack(runningSchedules, source.ptr);
	scope(exit) fp.dynarray.popBack(runningSchedules);

	// `opt.runSchedule` parsed this string already and refused the claim if it
	// did not take, so a second parse of the same text cannot fail.
	auto system = parseSystem(source);
	scope(exit) freeSystem(system);
	assert(system.valid());

	// Rooted at the module, not at the block: the calls this block owns are the
	// ones written outside it.
	immutable previousBlock = beginLoweringBlock(blockEntity);
	scope(exit) endLoweringBlock(previousBlock);
	const previousSchedule = beginLoweringSchedule(source);
	scope(exit) endLoweringSchedule(previousSchedule);
	system.subtree = currentCanonicalizeRoot;
	return system(mod);
}

/// Pass two: runs every claimed schedule.
///
/// `ecrs.system.sequential` over the entity store, rather than one of
/// `doir.systems`' tree walkers, because those now filter by ownership and a
/// claimed block is owned by itself: a walk looking for claims while no block
/// is being lowered skips every one of them. This combinator visits the store
/// directly and is not subject to the filter - which is also why a flat sweep
/// is right on its own terms, since a claim can sit on a block anywhere and
/// each one runs over the whole module regardless of the order they are found
/// in.
bool runRegisteredSchedules(ref Module mod) @trusted {
	// Stops at the first claim whose schedule failed, which is `sequential`'s
	// contract rather than a choice made here: a failed schedule has already
	// raised a diagnostic, and the stage hook ends the compile before anything
	// would have read what the remaining claims did or did not lower.
	return ecrs.system.sequential!(visitor!runRegisteredSchedule)(mod.ctx);
}

/// Pass one: claims the schedule `subtree` names on behalf of the block
/// `subtree` sits in, and replaces the call with the number of entities that
/// block holds - the same bargain `early_include` strikes, where the value is a
/// byproduct and the point is what the call did on its way to it.
///
/// Nothing runs here. `runRegisteredSchedules` is what runs, once every block
/// has claimed, so that `doir.systems.ownerOf` answers the same way for the
/// first claim as for the last.
bool runSchedule(ref Module mod, EntityId subtree) @trusted {
	if (!hasComponent!Call(mod, subtree)) return true;

	immutable runScheduleE = resolveCached(mod, "compiler.run_schedule", 1);
	if (resolveAlias(mod, getComponent!Call(mod, subtree).related[0]) != runScheduleE)
		return true;

	if (!hasComponent!FunctionInputs(mod, subtree)) {
		expectsXInputs(mod, subtree, "run_schedule", "one");
		return false;
	}
	auto inputs = resolvedInputs(mod, subtree);
	scope(exit) fp.dynarray.free(inputs);
	if (daLength(inputs) != 1) {
		expectsXInputs(mod, subtree, "run_schedule", "one");
		return false;
	}

	if (!hasComponent!DString(mod, inputs[0])) {
		parameterError(mod, subtree, "run_schedule", 0, " must evaluate to a string constant");
		return false;
	}
	// Interned, and on a different entity to the one emptied out below, so it
	// outlives everything this function does to the call - and outlives the
	// call itself, which is what lets the claim keep it as text.
	auto source = getComponent!DString(mod, inputs[0]).value;

	immutable blockEntity = findParent(mod, subtree);
	if (blockEntity == invalidEntity || !hasComponent!Block(mod, blockEntity)) {
		simpleCallError(mod, subtree, text("Used ", DoirAnsi.func, "run_schedule", Ansi.reset,
			" outside of a block"));
		return false;
	}

	// Parsed here only to check it, and thrown away again: what the claim keeps
	// is the text. Refusing a schedule that does not parse is the whole reason
	// this happens now rather than when the claim runs, since this is where
	// there is still a call to hang the diagnostic on.
	auto system = parseSystem(source.view);
	scope(exit) freeSystem(system);
	if (!system.valid()) {
		// Pointed into the schedule string itself, at the text that did not
		// parse - `inputs[0]` is that string, `subtree` only the call it was
		// handed to.
		reportSystemError(mod, system, source.view, inputs[0], "run_schedule");
		return false;
	}

	// Stop being a call. A schedule may perfectly well contain a pass that
	// visits calls - `computeCompilerNamespace`, or this pass - and it walks
	// the very block this call sits in, so a call still wearing its `Call`
	// component would be found again, claim again, and not stop.
	removeComponent!Call(mod, subtree);
	removeComponent!FunctionInputs(mod, subtree);
	removeComponent!TypeOf(mod, subtree);

	getOrAddComponent!ScheduleClaim(mod, blockEntity).source = source;

	attachNumber(mod, subtree, resolveCached(mod, "compiler.pointer_sized", 1),
		daLength(getComponent!Block(mod, blockEntity).related));
	return true;
}


// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest) {
	import tests.pipeline_helper;
}

unittest {
	// The whole point: a schedule written as a string, run over the block the
	// call sits in. The call is gone afterwards, replaced by how many entities
	// that block ended up holding.
	auto r = compile(
		"schedule : compiler.byte_pointer = \"depthFirst(pinRegisters)\"\n"
		~ "n : compiler.pointer_sized = compiler.run_schedule(schedule)\n");
	scope(exit) freeModule(r.mod);
	assert(r.ok);

	immutable n = find(r.mod, r.root, "n");
	assert(n != invalidEntity);
	assert(!hasComponent!Call(r.mod, n));
	assert(hasComponent!Number(r.mod, n));
	assert(getComponent!Number(r.mod, n).value > 0);
}

unittest {
	// The other half of the point: a call to something a scheduled block
	// declares is *not* that block's, unless it was written there.
	//
	// It used to be. `doir.systems.ownerOf` redirected a call to whoever
	// declared the callee, on the reasoning that calling `ns.f()` is a use of
	// `ns`'s declaration. That does not survive a second schedule: `mizu.doir`
	// claims its own block, so every `mizu.*` call in a module with a schedule
	// of its own belonged to mizu - and mizu's schedule never visits the block
	// those calls are written in, so they were lowered by nobody. Lowering edits
	// the site, so the site's block decides.
	//
	// `stripNames` is the probe because no schedule the compiler runs contains
	// it, so a name that is gone is a name this schedule reached and nothing
	// else could have. Both `x` and `y` are written outside `ns`, so both keep
	// their names.
	auto r = compile(
		"ns : namespace = {\n"
		~ "\tf : () -> compiler.byte = {\n"
		~ "\t\t_ : compiler.byte = 1\n"
		~ "\t}\n"
		~ "\ts : compiler.byte_pointer = \"depthFirst(stripNames)\"\n"
		~ "\t_ : compiler.pointer_sized = compiler.run_schedule(s)\n"
		~ "}\n"
		~ "x : compiler.byte = ns.f()\n"
		~ "y : compiler.byte = 2\n");
	scope(exit) freeModule(r.mod);
	assert(r.ok);

	assert(find(r.mod, r.root, "y") != invalidEntity);
	assert(find(r.mod, r.root, "x") != invalidEntity);
	diagnostics().clear();
}

unittest {
	// Whose schedule owns `m.x`, when `x` is a call to `ns.f` written inside
	// `m` and both blocks claimed a schedule? `m`'s - the block it is written
	// in. `ns` said how the declarations *in* `ns` are lowered, which is not the
	// same as saying how everybody else's calls to them are. So neither `m.x`
	// nor `m.y` is stripped: `m` asked for something harmless and got it.
	auto r = compile(
		"ns : namespace = {\n"
		~ "\tf : () -> compiler.byte = {\n"
		~ "\t\t_ : compiler.byte = 1\n"
		~ "\t}\n"
		~ "\ts : compiler.byte_pointer = \"depthFirst(stripNames)\"\n"
		~ "\t_ : compiler.pointer_sized = compiler.run_schedule(s)\n"
		~ "}\n"
		~ "m : namespace = {\n"
		~ "\ts : compiler.byte_pointer = \"depthFirst(pinRegisters)\"\n"
		~ "\t_ : compiler.pointer_sized = compiler.run_schedule(s)\n"
		~ "\tx : compiler.byte = ns.f()\n"
		~ "\ty : compiler.byte = 2\n"
		~ "}\n");
	scope(exit) freeModule(r.mod);
	assert(r.ok);

	assert(find(r.mod, r.root, "m.y") != invalidEntity);
	assert(find(r.mod, r.root, "m.x") != invalidEntity);
	diagnostics().clear();
}

unittest {
	// Claiming is taking over, not asking for extra: the module's own schedule
	// only runs on what nobody claimed.
	//
	// `inlineFunctions` is in the fallback schedule and not in `ns`'s, so the
	// identical `inline f()` is inlined outside `ns` and left standing inside
	// it. `f` itself is declared at the top level and claimed by nobody, so
	// `outside` is unowned and `inside` falls back on where it was written.
	auto r = compile(
		"f : () -> compiler.byte = {\n"
		~ "\t_ : compiler.byte = 1\n"
		~ "}\n"
		~ "outside : compiler.byte = inline f()\n"
		~ "ns : namespace = {\n"
		~ "\ts : compiler.byte_pointer = \"depthFirst(pinRegisters)\"\n"
		~ "\t_ : compiler.pointer_sized = compiler.run_schedule(s)\n"
		~ "\tinside : compiler.byte = inline f()\n"
		~ "}\n");
	scope(exit) freeModule(r.mod);
	assert(r.ok);

	immutable outside = find(r.mod, r.root, "outside");
	immutable inside = find(r.mod, r.root, "ns.inside");
	assert(outside != invalidEntity && inside != invalidEntity);
	assert(!hasComponent!Call(r.mod, outside)); // the fallback schedule inlined it
	assert(hasComponent!Call(r.mod, inside));   // `ns` owns it, and never asked
	diagnostics().clear();
}

unittest {
	// Every combinator is reachable from source, not just the walkers - this is
	// `mizuSchedule`'s own shape, written out in a string. It also names a pass
	// that visits calls, which is what the call has to stop being one before
	// the schedule runs: otherwise this finds itself, without end.
	auto r = compile(
		"schedule : compiler.byte_pointer = \"sequential("
		~ "fixedPoint(depthFirst(pinRegisters)),"
		~ "breadthFirst(allocateRegisters),"
		~ "parallel(breadthFirst(computeCompilerNamespace!false))"
		~ ")\"\n"
		~ "n : compiler.pointer_sized = compiler.run_schedule(schedule)\n");
	scope(exit) freeModule(r.mod);
	assert(r.ok);
	assert(!hasComponent!Call(r.mod, find(r.mod, r.root, "n")));
}

unittest {
	// Ditto for naming this very pass, which is registered like any other.
	auto r = compile(
		"schedule : compiler.byte_pointer = \"depthFirst(runSchedule)\"\n"
		~ "n : compiler.pointer_sized = compiler.run_schedule(schedule)\n");
	scope(exit) freeModule(r.mod);
	assert(r.ok);
	assert(!hasComponent!Call(r.mod, find(r.mod, r.root, "n")));
}

unittest {
	// A schedule that does not parse is a diagnostic on the call, not a
	// half-run schedule, and it is pointed at the offending text inside the
	// schedule string rather than at the call that was handed it.
	auto r = compile(
		"schedule : compiler.byte_pointer = \"depthFirst(no_such_pass)\"\n"
		~ "n : compiler.pointer_sized = compiler.run_schedule(schedule)\n");
	scope(exit) freeModule(r.mod);
	assert(!r.ok);
	assert(diagnostics().hasErrors());
	diagnostics().clear();
}

unittest {
	// The argument has to be a string the compiler can read *now*, the same
	// constraint `early_include` puts on its path.
	auto r = compile(
		"x : compiler.pointer_sized = 5\n"
		~ "n : compiler.pointer_sized = compiler.run_schedule(x)\n");
	scope(exit) freeModule(r.mod);
	assert(!r.ok);
	assert(diagnostics().hasErrors());
	diagnostics().clear();
}

unittest {
	// A module with no `run_schedule` in it is left alone - the pass is scheduled
	// over every entity of every compile, so saying nothing is the common case.
	auto r = compile("n : compiler.pointer_sized = 5\n");
	scope(exit) freeModule(r.mod);
	assert(r.ok);
	assert(runSchedule(r.mod, find(r.mod, r.root, "n")));
	assert(!diagnostics().hasErrors());
}
