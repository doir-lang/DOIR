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
import doir.pipeline.sema.comptime;
import doir.pipeline.sema.function_arity;
import doir.pipeline.sema.lookup;
import doir.pipeline.sema.materialize;
import doir.pipeline.sema.name_reuse;
import doir.pipeline.sema.process_early_include;
import doir.pipeline.sema.sort;
import doir.systems;
import doir.verify;

import doir.pipeline.opt.allocate_registers;
import doir.pipeline.opt.compute_compiler_namespace;
import doir.pipeline.opt.inline_functions;
import doir.pipeline.opt.materialize_aliases;
import doir.pipeline.opt.mizu.comptime_evaluate;
import doir.pipeline.opt.mizu.materialize_immediates;
import doir.pipeline.opt.mizu.materialize_labels;
import doir.pipeline.opt.pin_registers;
import doir.pipeline.opt.strip_freestanding_blocks;

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

private bool comptimeEvaluateVisitor(ref Module mod, EntityId e) {
	return comptimeEvaluate(mod, e, &moduleSystem!mizuSchedule);
}


// ---------------------------------------------------------------------------
// Schedules
// ---------------------------------------------------------------------------
//
// Each schedule is a plain `bool(ref Module)` pass built out of `doir.systems`'
// walkers and combinators; `moduleSystem!schedule` turns one into the libECRS
// system that `comptimeEvaluate` (and `ecrs.system`'s own combinators) take.

/// The schedule the comptime evaluator runs over each block it lowers.
bool mizuSchedule(ref Module mod) {
	// NOTE: `materialize_aliases` is commented out in driver.cpp's mizu
	// schedule; it is ported (doir.pipeline.opt.materialize_aliases) but likewise
	// unused here.
	return sequential(
		depthFirst!pinRegisters(),
		breadthFirst!allocateRegisters(),
		depthFirst!pinRegisters(),
		breadthFirst!(computeCompilerNamespaceVisitor!false)(),
		depthFirst!materializeImmediates(),
		depthFirst!materializeLabels(),
		breadthFirst!inlineFunctions(),
		breadthFirst!(computeCompilerNamespaceVisitor!true)(),
	)(mod);
}

bool canonicalizeSchedule(ref Module mod, EntityId root, ref BlockBuilder* builders) {
	earlyIncludeContext.builders = &builders;
	sortSystem(mod, root);
	return sequential(
		sorted!processEarlyIncludeVisitor(currentCanonicalizeRoot, true),
		sorted!materializeFunctionTypesAndParameters(currentCanonicalizeRoot, true),
	)(mod);
}

bool semaSchedule(ref Module mod) {
	immutable ok = sequential(
		depthFirst!nameReuse(),
		depthFirst!(resolveLookupsVisitor!true)(),
		depthFirst!materializeFunctionTypesAndParameters(),
		// We may have materialized some function parameters which can now be found
		depthFirst!(resolveLookupsVisitor!false)(),
		depthFirst!lookupsResolved(),
		fixedPoint(depthFirst!bubbleComptime()),
		depthFirst!validateComptime(),
		depthFirst!functionArity(),
	)(mod);
	if (!ok) return false;

	sortSystem(mod);
	return true;
}

bool optSchedule(ref Module mod) {
	return sequential(
		fixedPoint(depthFirst!comptimeEvaluateVisitor()),
		breadthFirst!stripFreestandingBlocks(),
		&moduleSystem!mizuSchedule,
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

/// Runs everything after parsing - structure, canonicalize, sema, opt, and the
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

	semaSchedule(mod);
	if (!hook()) return invalidEntity;

	optSchedule(mod);
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
	import doir.pipeline.sema.sort : newRoot;
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

	BlockBuilder* builders;
	scope(exit) fp.dynarray.free(builders);
	{
		auto builtin = createBlockBuilder(mod);
		buildBuiltinBlock(builtin);
		fp.dynarray.pushBack(builders, builtin);
	}

	assert(parseFile(mod, builders, "test.doir"));
	assert(!diagnostics().hasErrors());

	immutable root = runPipeline(mod, builders);
	assert(root != invalidEntity);
	assert(!diagnostics().hasErrors());
	assert(root == newRoot);

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

	BlockBuilder* builders;
	scope(exit) fp.dynarray.free(builders);
	{
		auto builtin = createBlockBuilder(mod);
		buildBuiltinBlock(builtin);
		fp.dynarray.pushBack(builders, builtin);
	}

	assert(parseFile(mod, builders, "test_string.doir"));
	immutable root = runPipeline(mod, builders);
	assert(root != invalidEntity);
	assert(!diagnostics().hasErrors());

	internIn(mod, "compiler.emit");
	internIn(mod, "compiler.emit_bytes");
	ByteEmiter emiter;
	scope(exit) emiter.free();
	auto bytes = emitAll(emiter, mod, newRoot);
	scope(exit) bytes.free();
	assert(bytes.length > 0);
	assert(bytes.slice == cast(const(ubyte)[]) "Hello World");
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

	BlockBuilder* builders;
	scope(exit) fp.dynarray.free(builders);
	{
		auto builtin = createBlockBuilder(mod);
		buildBuiltinBlock(builtin);
		fp.dynarray.pushBack(builders, builtin);
	}
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
