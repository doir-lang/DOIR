/// The compile pipeline itself: the pass schedules the driver runs, and the
/// order it runs them in.
///
/// This lives in the library rather than in `main.d` so the driver and the
/// tests share one definition - a test that claims to exercise "what a real
/// compile does" is only worth anything if it is running the same schedule
/// the driver does, and that can't be guaranteed while the two are separate
/// copies that drift apart.
module doir.pipeline;

import ecrs.storage : EntityId, invalidEntity;

import doir.diagnostics;
import doir.interface_;
import doir.module_;
import doir.systems;
import doir.verify;

import doir.pipeline.canon.comptime;
import doir.pipeline.canon.lookup;
import doir.pipeline.canon.materialize;
import doir.pipeline.canon.override_fallback_schedule;
import doir.pipeline.canon.process_early_include;
import doir.pipeline.canon.sort;
import doir.pipeline.canon.strip_freestanding_blocks;

import doir.pipeline.sema.function_arity;
import doir.pipeline.sema.monomorphize;
import doir.pipeline.sema.name_reuse;
import doir.pipeline.sema.type_check;
import doir.pipeline.sema.type_deduction;
import doir.pipeline.sema.type_properties;
import doir.pipeline.sema.type_variables;

import doir.pipeline.opt.allocate_registers;
import doir.pipeline.opt.compute_compiler_namespace;
import doir.pipeline.opt.inline_functions;
import doir.pipeline.opt.materialize_aliases;
import doir.pipeline.opt.mizu.comptime_evaluate;
import doir.pipeline.opt.mizu.materialize_immediates;
import doir.pipeline.opt.mizu.materialize_labels;
import doir.pipeline.opt.pin_registers;
import doir.pipeline.opt.run_schedule;

@nogc nothrow:


// ---------------------------------------------------------------------------
// Visitors that need a bound argument
// ---------------------------------------------------------------------------
//
// A walker takes its visitor as a compile-time alias, so a pass whose extra
// argument is a constant binds it as a template argument rather than through
// a mutable global the walk reads back.

private bool resolveLookupsVisitor(bool typesOnly)(ref Module mod, EntityId e) {
	return resolveLookups(mod, e, typesOnly);
}

/// Public because `doir.dynamic_systems` registers it: the pass underneath
/// (`comptimeEvaluate`) takes the schedule it lowers each block with as an
/// argument, which a schedule string has no way to write, so this binding is
/// the only spelling of it a string can name.
///
/// What it binds is `runFallbackSchedule`, not a fixed backend: a block lowered
/// to run at compile time is lowered the same way the module around it will be,
/// so a program that overrode the fallback schedule overrode this too.
bool comptimeEvaluateVisitor(ref Module mod, EntityId e) {
	return comptimeEvaluate(mod, e, &moduleSystem!runFallbackSchedule);
}


// ---------------------------------------------------------------------------
// Schedules
// ---------------------------------------------------------------------------
//
// Each schedule is a plain `bool(ref Module)` pass built out of `doir.systems`'
// walkers and combinators; `moduleSystem!schedule` turns one into the libECRS
// system that `comptimeEvaluate` (and `ecrs.system`'s own combinators) take.

/// The lowering schedule the compiler falls back on when nothing overrode it -
/// the mizu backend, which is the only one built in.
///
/// `mizu.doir` carries this same list as a `compiler.override_fallback_schedule`
/// string, and that is what lowers a program which early_include's it. This
/// copy stays because a program that includes no backend at all still has to
/// compile: most of what is below is not the mizu backend -
/// `computeCompilerNamespace` folds the `compiler.*` namespace, and the builtin
/// block's own `compiler.byte` is a `compiler.base_type` call waiting to be
/// folded - so with nothing standing in, a module with no `early_include` would
/// not get a usable `compiler.byte`.
///
/// The three passes it opens with are here rather than in `canonicalizeSchedule`
/// because they are answerable to
/// the backend rather than to the language: what counts as a name collision,
/// what a function's arity is, and when a block-scoped `compiler.run_schedule`
/// gets its turn are all things a backend should be able to say differently -
/// and a pass the compiler runs before handing over is one it has already
/// decided for everyone.
///
/// `validateComptime` was meant to be a fourth and stayed behind; see the note
/// on `canonicalizeSchedule` for why.
bool mizuSchedule(ref Module mod) {
	// NOTE: `materialize_aliases` is commented out in driver.cpp's mizu
	// schedule; it is ported (doir.pipeline.opt.materialize_aliases) but likewise
	// unused here.
	return sequential(
		depthFirst!nameReuse(),
		depthFirst!functionArity(),
		// The type system's post-comptime half. Here rather than in
		// `canonicalizeSchedule` for the same reason as the two above - what
		// counts as a type mismatch, and how an aggregate is laid out, are a
		// backend's to say - and *after* comptime because that is what M-Freeze
		// licenses: every modifier is a comptime call, so by this point each
		// type has exactly one answer rather than one per lexical position (P2).
		// Before `typeCheck`, so that `compiler.byte` and `mizu.u64` have a
		// layout for S-Struct to compare rather than being the `base_type` calls
		// they are written as. Only the `base_type` half of
		// `computeCompilerNamespace`; the rest of it still runs below, after
		// registers are allocated.
		breadthFirst!foldBaseTypes(),
		depthFirst!typeCheck(),
		depthFirst!computeTypeProperties(),
		// The one place a schedule a user wrote in their source can see what the
		// lowering is about to do: after it, but before any of it has run. See
		// `doir.pipeline.opt.run_schedule` on why it is not one of the
		// `compiler.*` builtins `computeCompilerNamespace` folds, and why
		// claiming and running are two passes rather than one.
		depthFirst!runSchedule(),
		&moduleSystem!runRegisteredSchedules,
		depthFirst!pinRegisters(),
		breadthFirst!allocateRegisters(),
		depthFirst!pinRegisters(),
		breadthFirst!(computeCompilerNamespaceVisitor!false)(),
		depthFirst!materializeImmediates(),
		depthFirst!materializeLabels(),
		// Before inlining, which would otherwise copy the unspecialized body in
		// and leave nothing to specialize. `sorted` rather than `depthFirst`
		// because it splices declarations into the block it is walking - and
		// *without* its re-sort, which renumbers every entity in the module and
		// so cannot happen part way through a lowering schedule that is holding
		// ids of its own. The copies are parented and listed either way; all the
		// sort would restore is the contiguous-id invariant, which nothing below
		// here asks for.
		sorted!monomorphizeFunctions(currentCanonicalizeRoot, false),
		breadthFirst!inlineFunctions(),
		breadthFirst!(computeCompilerNamespaceVisitor!true)(),
	)(mod);
}

/// Everything between parsing and the final sort: canonicalizing the tree,
/// resolving it, then evaluating and lowering it.
///
/// This was three schedules not long ago - `canonicalizeSchedule`,
/// `canonicalizeSchedule`, `optSchedule` - run back to back by `runPipeline`. None of
/// the boundaries between them was worth keeping: nothing ever looked at a
/// module that had been through one and not the next, and having them meant
/// "have the includes been pulled in yet?", "has comptime run yet?" and "has
/// this module's own schedule run yet?" were questions with a different answer
/// depending on which stage you were standing in. One schedule gives each of
/// them one answer - when this returns, every `early_include` has been spliced
/// in, comptime has run, every schedule the source asked for has run, and the
/// module has been lowered.
///
/// What is left inside are three phases separated by sorts, and the sorts are
/// the reason they are still distinguishable at all. Each phase adds entities -
/// included files, materialized function types and parameters, blocks the
/// comptime evaluator builds - and `sortSystem` is what renumbers them into the
/// order the next phase's walks need to already be in.
bool canonicalizeSchedule(ref Module mod, EntityId root, ref BlockBuilder* builders) {
	clearFallbackScheduleOverride();
	earlyIncludeContext.builders = &builders;

	// Canonicalize: splice in every `early_include` and materialize what it
	// brought with it, until a round changes nothing. An included file can
	// include more, hence the fixed point; each pass re-sorts because it is
	// adding entities to the block it is walking.
	// `sortSystem` in the schedule below takes `currentCanonicalizeRoot`, which
	// resolves to `newRoot` - unset on the first compile in the process, and
	// the previous module's root on every one after. Seed it from the parser's
	// root so the first sort sorts this tree. (Assigned rather than sorted for:
	// the sort itself is the schedule's first entry.)
	newRoot = root;

	return sequential(
		fixedPoint(sequential(
			&moduleSystem!sortSystem,
			sorted!processEarlyIncludeVisitor(currentCanonicalizeRoot, false),
			sorted!materializeFunctionTypesAndParameters(currentCanonicalizeRoot, false),
		)),
		&moduleSystem!sortSystem,

		depthFirst!(resolveLookupsVisitor!true)(),
		depthFirst!materializeFunctionTypesAndParameters(),
		// We may have materialized some function parameters which can now be found
		depthFirst!(resolveLookupsVisitor!false)(),
		depthFirst!lookupsResolved(),
		// `_` in type position resolves like any other name, to the one builtin
		// entity named `_`; this is what makes two holes in a module two
		// variables rather than one shared placeholder. Pure syntax - it reads
		// no value and folds nothing - so it runs once, here, rather than in the
		// fixpoint below that solves what it introduces.
		depthFirst!introduceTypeVariables(),
		fixedPoint(depthFirst!bubbleComptime()),
		// Not moved out to the backend with `nameReuse` and `functionArity`,
		// though it was meant to be. It reports a compile time call handed a
		// value that is not compile time known, and lowering manufactures
		// those: `opt.inlineFunctions` copies a body in with its parameters
		// replaced by the caller's runtime values, and every copied
		// `compiler.shift_right(r, 8)` in `mizu.doir` then looks like the thing
		// this rejects. The check only holds ahead of any lowering, which is
		// here.
		depthFirst!validateComptime(),

		// sortSystem,

		// Solving and evaluating are interleaved rather than ordered, because
		// each needs the other: a type is a comptime value, so the type a hole
		// should take is usually a call that has not been folded yet - and by
		// D-Deduce a solved `deduced` parameter becomes a comptime argument to
		// the call it was solved for. One fixpoint over the pair settles both,
		// a level per round. `deduceTypes` is the monotone half, deliberately;
		// see its module comment and @comptime's note on the other one.
		fixedPoint(sequential(
			depthFirst!deduceTypes(),
			depthFirst!comptimeEvaluateVisitor(),
		)),
		breadthFirst!stripFreestandingBlocks(),
		// Pass one of `compiler.override_fallback_schedule`, and it has to be
		// here: `comptimeEvaluateVisitor` below lowers with whatever this
		// settles on, so the answer has to be settled before the first comptime
		// call is evaluated rather than alongside them.
		depthFirst!findFallbackScheduleOverride(),
		// Pass two: lower, with the module's own schedule if it named one.
		&moduleSystem!runFallbackSchedule,
	)(mod);
}


// ---------------------------------------------------------------------------
// Driving the schedules
// ---------------------------------------------------------------------------

/// Called after each stage of `runPipeline`; returning `false` aborts the
/// compile. The driver reports (prints) what has accumulated, the tests just
/// check - hence the hook rather than a fixed policy baked in here.
alias StageHook = bool function() @nogc nothrow;

/// The default policy: stop as soon as a stage has raised an error, silently.
bool stopOnError() {
	return !diagnostics().hasErrors();
}

/// Runs everything after parsing - structure, canonicalize, sema, and the
/// final sort - over a module whose source has already been parsed into
/// `builders`, the parser's stack of open blocks (a libfp dynarray whose
/// bottom entry is the builtin block).
///
/// Returns the final (post-sort) root entity, or `invalidEntity` if `hook`
/// stopped the compile. Diagnostics are left in `diagnostics()` either way.
EntityId runPipeline(ref Module mod, ref BlockBuilder* builders, StageHook hook = &stopOnError) {
	auto root = builders[0].block;
	structure(diagnostics(), mod, root);
	if (!hook()) return invalidEntity;

	canonicalizeSchedule(mod, root, builders);
	if (!hook()) return invalidEntity;

	root = sort(mod, newRoot);
	structure(diagnostics(), mod, root);
	return root;
}


// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
//
// The per-pass tests live beside the passes; what is left for here is the
// schedule as a whole - that a real program, with every stage doing real work,
// comes out the far end.

version (unittest) {
	static import fp.dynarray;

	import diagnose.source_location : SourceLocation;

	import doir.parser : parseFile, parseSource;
	import doir.pipeline.canon.sort : newRoot;
	import tests.pipeline_helper;
}

unittest {
	// `test.doir` is the repository's own end-to-end program: it
	// `early_include`s the whole Mizu instruction binding file, declares a
	// quoted block, runs it on the comptime VM through `mizu.doir.execute_if`,
	// and pins registers on the result. Compiling it drives every stage of the
	// pipeline over real input - which is the only way most of `opt/mizu` and
	// `sema.processEarlyInclude` are reached at all.
	diagnostics().clear();
	auto mod = createModule();
	scope(exit) freeModule(mod);

	auto builders = createBuilderStack(mod);
	scope(exit) fp.dynarray.free(builders);

	assert(parseFile(mod, builders, "test.doir"));
	assert(!diagnostics().hasErrors());

	immutable root = runPipeline(mod, builders);
	assert(root != invalidEntity);
	assert(!diagnostics().hasErrors());
	assert(root == newRoot);

	// `mizu.doir` ends in a `compiler.override_fallback_schedule`, so the module
	// was lowered by the schedule written in that file rather than by
	// `mizuSchedule`. The two currently list the same passes, which is exactly
	// why this is worth asserting: a fallback would look identical in the
	// output.
	assert(hasFallbackScheduleOverride());

	// The block the program executes at compile time was inlined into the call
	// that ran it, so its body is present in the output rather than the call.
	assert(resolveLookupName(mod, internIn(mod, "e"), root) != invalidEntity);
	diagnostics().clear();
}

unittest {
	// ...and `test_string.doir`, which is nothing but `compiler.emit` calls, so
	// the byte emiter has something to emit.
	import doir.byte_emiter;

	diagnostics().clear();
	auto mod = createModule();
	scope(exit) freeModule(mod);

	auto builders = createBuilderStack(mod);
	scope(exit) fp.dynarray.free(builders);

	assert(parseFile(mod, builders, "test_string.doir"));
	immutable root = runPipeline(mod, builders);
	assert(root != invalidEntity);
	assert(!diagnostics().hasErrors());

	internIn(mod, "compiler.emit");
	internIn(mod, "compiler.emit_bytes");
	auto bytes = emitAll(mod, newRoot);
	scope(exit) fp.dynarray.free(bytes);
	assert(fp.dynarray.slice(bytes) == cast(const(ubyte)[]) "Hello World");
	diagnostics().clear();
}

unittest {
	// ...and `test_standard.doir`, which is the assembler layer `standard.doir`
	// assumes plus an `early_include` of it. The standard interface is where
	// `deduced` actually lives - 36 positions, every arithmetic, comparison and
	// memory primitive - so this is the end-to-end test of D-Deduce, and the
	// only thing in the repository that compiles the file the language is
	// specified against.
	diagnostics().clear();
	auto mod = createModule();
	scope(exit) freeModule(mod);

	auto builders = createBuilderStack(mod);
	scope(exit) fp.dynarray.free(builders);

	assert(parseFile(mod, builders, "test_standard.doir"));
	assert(!diagnostics().hasErrors());

	immutable root = runPipeline(mod, builders);
	assert(root != invalidEntity);
	assert(!diagnostics().hasErrors());

	// `move`'s body is the file's one call through a deduced parameter:
	// `_ : _ = return(%0)`, which is short an argument as written. It compiles
	// only if `T` was solved from `%0` and spliced in - and the hole on the left
	// only if the `-> T` was then read back through that solution.
	immutable move = resolveLookupName(mod, internIn(mod, "std.move"), root);
	assert(move != invalidEntity);

	immutable return_ = resolveLookupName(mod, internIn(mod, "std.return"), root);
	bool elaborated = false;
	auto body_ = &getComponent!Block(mod, move);
	foreach (i; 0 .. fp.dynarray.length(body_.related)) {
		immutable child = body_.related[i];
		if (!hasComponent!Call(mod, child)) continue;
		if (resolveAlias(mod, getComponent!Call(mod, child).related[0]) != return_) continue;

		auto args = &getComponent!FunctionInputs(mod, child);
		assert(fp.dynarray.length(args.related) == 2);
		// Solved forward from the value: `move`'s own `T`, which is also what
		// the hole on the left ends up with.
		assert(resolveAlias(mod, args.related[0])
			== resolveAlias(mod, getComponent!TypeOf(mod, args.related[1]).related[0]));
		assert(resolveAlias(mod, args.related[0])
			== resolveAlias(mod, getComponent!TypeOf(mod, child).related[0]));
		elaborated = true;
	}
	assert(elaborated);
	diagnostics().clear();
}

unittest {
	// The stage hook is what stops a compile part way: the driver prints and
	// stops on an error, the tests just stop. One that always refuses aborts
	// at the first stage boundary, and `runPipeline` says so with
	// `invalidEntity` rather than by leaving a half-built root behind.
	static bool refuse() { return false; }

	diagnostics().clear();
	auto mod = createModule();
	scope(exit) freeModule(mod);

	auto builders = createBuilderStack(mod);
	scope(exit) fp.dynarray.free(builders);
	assert(parseSource(mod, builders, "%1 : compiler.byte = 5\n", "hook.doir"));

	assert(runPipeline(mod, builders, &refuse) == invalidEntity);
	diagnostics().clear();
}

unittest { // `stopOnError` is the default policy: it only stops once one is raised
	diagnostics().clear();
	assert(stopOnError());
	pushDiagnostic(DiagnosticType.InvalidType, SourceLocation("t.doir", 0, 0), "", "t.doir");
	assert(!stopOnError());
	diagnostics().clear();
}
