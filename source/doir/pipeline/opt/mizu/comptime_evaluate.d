/// `opt.mizu.comptimeEvaluate`: builds a tiny Mizu program that performs one
/// compile-time call, runs it, and lets the DOIR instructions write the
/// result back into the module. Ported from opt/mizu/comptime_evaluate.cpp.
module doir.pipeline.opt.mizu.comptime_evaluate;

import core.stdc.stdio : printf, snprintf;

import ecrs.storage : EntityId, invalidEntity;

static import fp.dynarray;
import fp.dynarray : daLength = length;

import mizu.opcode : setupEnvironment, startFromEnvironment;

import doir.byte_emiter;
import doir.interface_;
import doir.mizu.instructions : doirLookup;
import mizu.portable_format : fromPortable;
import doir.module_;
import doir.diagnostics : panic;
import doir.pipeline.sema.sort : newRoot;
import doir.string_helpers : InternedString, wildcardName;
import doir.systems : SystemFunction, fixedPointChanged;

@nogc nothrow:


/// True if `subtree` already has a value the compiler can read directly.
bool comptimeValueAvailable(ref Module mod, EntityId subtree) {
	immutable type = resolveCached(mod, "type", 1, true);
	immutable blockType = resolveCached(mod, "block", 1, true);

	return hasComponent!Number(mod, subtree) || hasComponent!DString(mod, subtree)
		|| hasComponent!ComptimeNumber(mod, subtree) || hasComponent!ComptimeString(mod, subtree)
		|| (hasComponent!TypeOf(mod, subtree)
			&& (getComponent!TypeOf(mod, subtree).related[0] == type
				|| getComponent!TypeOf(mod, subtree).related[0] == blockType));
}

/// The instructions `comptimeEvaluate` must not run.
///
/// The program it builds holds one call and a `halt`, assembled fresh for
/// that one call - so an instruction that moves the program counter has
/// nowhere in *that* program to move to. `jump_to` is handed an address in
/// the real one (address 0, for a label whose instruction has not been
/// emitted yet), and the VM leaves for it, taking the compiler with it;
/// `find_label` is the other half of the same story, scanning the throwaway
/// program for a label that only exists in the real one and folding its
/// "not found" 0 back into the caller as though it were an address. `halt`
/// would end the program before it started, and a `label`'s value is
/// `opt.mizu.materializeLabels`' to hand out rather than anything the VM
/// computes.
private static immutable string[9] neverComptime = [
	"mizu.halt",
	"mizu.label",
	"mizu.find_label",
	"mizu.jump_relative",
	"mizu.jump_relative_immediate",
	"mizu.jump_to",
	"mizu.branch_relative",
	"mizu.branch_relative_immediate",
	"mizu.branch_to",
];

/// Evaluates `subtree` by assembling it into a throwaway block and running it
/// on the Mizu VM. `mizuSchedule` is the schedule that lowers that block -
/// any libECRS system, so the driver can hand over whatever it composed out of
/// `doir.systems`' walkers (see `doir.systems.moduleSystem` for turning one
/// into the function pointer this takes).
bool comptimeEvaluate(ref Module mod, EntityId subtree, SystemFunction mizuSchedule) @trusted {
	if (!hasComponent!Call(mod, subtree)) return true;
	if (!flagsSet(mod, subtree, Flags.Comptime)) return true;
	if (comptimeValueAvailable(mod, subtree)) return true;

	if (hasComponent!FunctionInputs(mod, subtree)) {
		auto inputs = &getComponent!FunctionInputs(mod, subtree);
		foreach (i; 0 .. daLength(inputs.related))
			if (!comptimeValueAvailable(mod, inputs.related[i])) return true;
	}

	immutable compiler = resolveCached(mod, "compiler", 1, true);
	immutable assembler = resolveCached(mod, "compiler.assembler", 1, true);
	immutable calledFunction = resolveAlias(mod, getComponent!Call(mod, subtree).related[0]);
	// Nothing to run if the call has no target. `invalidEntity` is 0, so
	// leaving this open would also let an unresolved callee compare equal to
	// any `mizu.*` name this module never resolved.
	if (calledFunction == invalidEntity) return true;
	immutable calleeParent = findParent(mod, calledFunction);
	// Compiler functions have their own pass and shouldn't really be used
	// outside of the mizu backend.
	if (calleeParent == compiler || calleeParent == assembler) return true;

	foreach (name; neverComptime)
		if (calledFunction == resolveCached(mod, name, 1, true)) return true;

	immutable type = resolveCached(mod, "type", 1, true);
	immutable blockType = resolveCached(mod, "block", 1, true);
	immutable voidType = resolveCached(mod, "void", 1, true);
	immutable earlyInclude = resolveCached(mod, "early_include", 5, true);

	immutable compilerCurrentEntity = resolveCached(mod, "compiler.current_entity", 1, true);
	immutable assemblerPinRegister = resolveCached(mod, "compiler.assembler.pin_register", 1, true);
	immutable assemblerRegister = resolveCached(mod, "compiler.assembler.register", 1, true);

	immutable mizuNs = resolveCached(mod, "mizu", 1, true);
	immutable mizuU64 = resolveCached(mod, "mizu.u64", 1, true);
	immutable mizuHalt = resolveCached(mod, "mizu.halt", 1, true);
	immutable mizuLoadImmediate = resolveCached(mod, "mizu.load_immediate", 1, true);
	immutable mizuLoadUpperImmediate = resolveCached(mod, "mizu.load_upper_immediate", 1, true);
	immutable mizuDoirSetModule = resolveCached(mod, "mizu.doir.set_module", 1, true);
	immutable mizuDoirAttachComptimeNumberI64 =
		resolveCached(mod, "mizu.doir.attach_comptime_number_i64", 1, true);

	// Every one of these is needed to assemble the throwaway program below, and
	// every one of them is `invalidEntity` (0) in a module that never
	// early_include'd mizu.doir. Building the block anyway emitted bytes that
	// decode to nothing, and `startFromEnvironment` then jumped the VM into a
	// wild address - a segfault for any comptime call in a module with no mizu
	// backend loaded (a zero-argument call is vacuously comptime, so this is
	// easy to reach). Leave the call alone instead, the way a `compiler.*`
	// callee is left alone above.
	if (mizuNs == invalidEntity || mizuU64 == invalidEntity || mizuHalt == invalidEntity
		|| mizuLoadImmediate == invalidEntity || mizuLoadUpperImmediate == invalidEntity
		|| mizuDoirSetModule == invalidEntity
		|| mizuDoirAttachComptimeNumberI64 == invalidEntity)
		return true;

	getComponent!Number(mod, compilerCurrentEntity).value = subtree;

	fixedPointChanged() = true;

	auto comptimeBlock = createBlockBuilder(mod);
	{
		auto related = &getComponent!Block(mod, comptimeBlock.block).related;
		fp.dynarray.pushBack(*related, type);
		fp.dynarray.pushBack(*related, voidType);
		fp.dynarray.pushBack(*related, earlyInclude);
		fp.dynarray.pushBack(*related, compiler);
		fp.dynarray.pushBack(*related, mizuNs);
	}

	immutable modPtr = cast(size_t) &mod;
	auto currentModule = pushNumber(comptimeBlock, InternedString("_"), mizuU64, cast(uint) modPtr);
	size_t rValue = 1;
	// Two since the allocator tends to skip 2.
	auto r = pushNumber(comptimeBlock, InternedString("_"), assemblerRegister, rValue++);
	{
		EntityId[3] inputs = [mizuU64, currentModule, r];
		pushCall(comptimeBlock, InternedString("_"), assemblerRegister, assemblerPinRegister, inputs[]);
	}
	{
		EntityId[2] inputs = [mizuU64, currentModule];
		pushCall(comptimeBlock, InternedString("_"), assemblerRegister, mizuLoadImmediate, inputs[]);
	}
	currentModule = pushNumber(comptimeBlock, InternedString("_"), mizuU64, cast(uint)(modPtr >> 32));
	{
		EntityId[3] inputs = [mizuU64, currentModule, r];
		pushCall(comptimeBlock, InternedString("_"), assemblerRegister, assemblerPinRegister, inputs[]);
	}
	{
		EntityId[2] inputs = [mizuU64, currentModule];
		pushCall(comptimeBlock, InternedString("_"), assemblerRegister, mizuLoadUpperImmediate, inputs[]);
	}
	{
		EntityId[1] inputs = [currentModule];
		pushCall(comptimeBlock, InternedString("_"), assemblerRegister, mizuDoirSetModule, inputs[]);
	}

	auto currentEntity = pushNumber(comptimeBlock, InternedString("_"), mizuU64, subtree);
	r = pushNumber(comptimeBlock, InternedString("_"), assemblerRegister, rValue++);
	{
		EntityId[2] inputs = [mizuU64, currentEntity];
		pushCall(comptimeBlock, InternedString("_"), assemblerRegister, mizuLoadImmediate, inputs[]);
	}
	{
		EntityId[3] inputs = [mizuU64, currentEntity, r];
		pushCall(comptimeBlock, InternedString("_"), assemblerRegister, assemblerPinRegister, inputs[]);
	}

	EntityList arguments;
	scope(exit) arguments.free();
	if (hasComponent!FunctionInputs(mod, subtree)) {
		immutable count = daLength(getComponent!FunctionInputs(mod, subtree).related);
		foreach (i; 0 .. count) {
			auto e = resolveAlias(mod, getComponent!FunctionInputs(mod, subtree).related[i]);

			InternedString name;
			if (hasComponent!Name(mod, e))
				name = getComponent!Name(mod, e).value;
			else {
				char[24] buffer;
				immutable n = snprintf(buffer.ptr, buffer.length, "a%zu", i);
				name = internIn(mod, buffer[0 .. n]);
			}

			if (hasComponent!Number(mod, e))
				e = pushNumber(comptimeBlock, name, mizuU64, cast(size_t) getComponent!Number(mod, e).value);
			else if (hasComponent!ComptimeNumber(mod, e))
				e = pushNumber(comptimeBlock, name, mizuU64, cast(size_t) getComponent!ComptimeNumber(mod, e).value);
			else if (hasComponent!DString(mod, e))
				e = pushNumber(comptimeBlock, name, mizuU64, cast(size_t) getComponent!DString(mod, e).value.view.ptr);
			else if (hasComponent!ComptimeString(mod, e))
				e = pushNumber(comptimeBlock, name, mizuU64, cast(size_t) getComponent!ComptimeString(mod, e).value.view.ptr);
			else if (hasComponent!TypeOf(mod, e)
				&& (getComponent!TypeOf(mod, e).related[0] == blockType
					|| getComponent!TypeOf(mod, e).related[0] == type))
				e = pushNumber(comptimeBlock, name, mizuU64, resolveAlias(mod, e));
			else
				panic("Comptime evaluation of call with non-comptime parameter");

			{
				EntityId[2] inputs = [mizuU64, e];
				pushCall(comptimeBlock, InternedString("_"), assemblerRegister, mizuLoadImmediate, inputs[]);
			}
			r = pushNumber(comptimeBlock, InternedString("_"), assemblerRegister, rValue++);
			{
				EntityId[3] inputs = [mizuU64, e, r];
				pushCall(comptimeBlock, InternedString("_"), assemblerRegister, assemblerPinRegister, inputs[]);
			}
			arguments.push(e);
		}
	}

	immutable typeOfSubtree = resolveAlias(mod, getComponent!TypeOf(mod, subtree).related[0]);
	auto name = hasComponent!Name(mod, subtree)
		? getComponent!Name(mod, subtree).value
		: wildcardName();
	auto ret = pushCall(comptimeBlock, name, typeOfSubtree, calledFunction, arguments.slice);
	r = pushNumber(comptimeBlock, InternedString("_"), assemblerRegister, rValue++);
	{
		EntityId[3] inputs = [mizuU64, ret, r];
		pushCall(comptimeBlock, InternedString("_"), assemblerRegister, assemblerPinRegister, inputs[]);
	}

	// TODO: Store back string
	{
		EntityId[2] inputs = [currentEntity, ret];
		pushCall(comptimeBlock, InternedString("_"), mizuU64, mizuDoirAttachComptimeNumberI64, inputs[]);
	}

	{
		EntityId[0] none;
		pushCall(comptimeBlock, InternedString("_"), mizuU64, mizuHalt, none[]);
	}

	// printf("Comptime evaluating: %u\n", subtree);

	immutable backup = newRoot;
	newRoot = comptimeBlock.block;
	mizuSchedule(mod.ctx);
	newRoot = backup;

	ByteEmiter emiter;
	scope(exit) emiter.free();
	auto bytes = emitAll(emiter, mod, comptimeBlock.block);
	scope(exit) bytes.free();

	{
		auto portable = fromPortable!doirLookup(bytes.slice);
		scope(exit) if (portable.program !is null) fp.dynarray.free(portable.program);

		immutable count = daLength(portable.program);
		// Nothing decoded - there is no entry point to jump to, and handing the
		// VM a null program counter runs whatever happens to be at address 0.
		if (count == 0) return true;
		setupEnvironment(portable.environment, portable.program, portable.program + count);
		startFromEnvironment(portable.program, portable.environment);
	}

	return true;
}


// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
//
// The ordinary path runs whenever a program calls a `mizu.*` function at
// compile time (see `doir.pipeline`'s end-to-end tests). What is left here is
// the argument shapes those programs happen not to use: a string constant, an
// already-evaluated comptime string, and an argument with no name of its own.

version (unittest) {
	import doir.parser : parseSource;
	import doir.pipeline : mizuSchedule, runPipeline;
	import doir.diagnostics : diagnostics;
	import doir.systems : moduleSystem;
	import tests.pipeline_helper : compile;

	/// A module that has `mizu.doir` loaded and has been through the pipeline,
	/// so every `mizu.*` name the evaluator needs resolves.
	private struct MizuFixture {
		Module mod;
		EntityId root;
	}

	private MizuFixture makeMizuFixture() @trusted {
		diagnostics().clear();

		MizuFixture f;
		f.mod = createModule();

		BlockBuilder* builders;
		scope(exit) fp.dynarray.free(builders);
		{
			auto builtin = createBlockBuilder(f.mod);
			buildBuiltinBlock(builtin);
			fp.dynarray.pushBack(builders, builtin);
		}

		assert(parseSource(f.mod, builders,
			"path : compiler.byte_pointer = \"./mizu.doir\"\n"
			~ "_ : compiler.byte = early_include(path)\n", "comptime.doir"));
		f.root = runPipeline(f.mod, builders);
		assert(f.root != invalidEntity);
		assert(!diagnostics().hasErrors());
		return f;
	}

	/// `mizu.add(a, b)`, marked comptime, pushed into the fixture's root.
	private EntityId pushComptimeAdd(ref MizuFixture f, const(EntityId)[] args) {
		auto block = BlockBuilder(f.root, &f.mod);
		immutable u64 = resolveLookupName(f.mod, internIn(f.mod, "mizu.u64"), f.root);
		immutable add = resolveLookupName(f.mod, internIn(f.mod, "mizu.add"), f.root);
		assert(u64 != invalidEntity && add != invalidEntity);

		immutable call = pushCall(block, InternedString("_"), u64, add, args);
		getOrAddComponent!Flags(f.mod, call).flags |= Flags.Comptime;
		return call;
	}
}

unittest { // a string constant is passed to the VM as the address of its bytes
	auto f = makeMizuFixture();
	scope(exit) freeModule(f.mod);

	auto block = BlockBuilder(f.root, &f.mod);
	immutable bytePointer = resolveLookupName(f.mod,
		internIn(f.mod, "compiler.byte_pointer"), f.root);
	immutable s = pushString(block, internIn(f.mod, "s"), bytePointer, internIn(f.mod, "hi"));

	EntityId[2] args = [s, s];
	immutable call = pushComptimeAdd(f, args[]);
	assert(comptimeEvaluate(f.mod, call, &moduleSystem!mizuSchedule));
	assert(!diagnostics().hasErrors());
	diagnostics().clear();
}

unittest { // ...and so is one that an earlier round already evaluated
	auto f = makeMizuFixture();
	scope(exit) freeModule(f.mod);

	auto block = BlockBuilder(f.root, &f.mod);
	immutable bytePointer = resolveLookupName(f.mod,
		internIn(f.mod, "compiler.byte_pointer"), f.root);
	immutable s = pushValueless(block, internIn(f.mod, "s"), bytePointer);
	addComponent!ComptimeString(f.mod, s).value = internIn(f.mod, "hi");

	EntityId[2] args = [s, s];
	immutable call = pushComptimeAdd(f, args[]);
	assert(comptimeEvaluate(f.mod, call, &moduleSystem!mizuSchedule));
	assert(!diagnostics().hasErrors());
	diagnostics().clear();
}

unittest { // an argument with no name of its own gets a generated one
	auto f = makeMizuFixture();
	scope(exit) freeModule(f.mod);

	auto block = BlockBuilder(f.root, &f.mod);
	immutable u64 = resolveLookupName(f.mod, internIn(f.mod, "mizu.u64"), f.root);
	// `_` is the discard name, which `pushCommon` attaches no `Name` for.
	immutable anonymous = pushNumber(block, InternedString("_"), u64, 3);
	assert(!hasComponent!Name(f.mod, anonymous));

	EntityId[2] args = [anonymous, anonymous];
	immutable call = pushComptimeAdd(f, args[]);
	assert(comptimeEvaluate(f.mod, call, &moduleSystem!mizuSchedule));
	assert(!diagnostics().hasErrors());
	diagnostics().clear();
}

unittest { // calls the evaluator has nothing to do with are left alone
	auto f = makeMizuFixture();
	scope(exit) freeModule(f.mod);

	auto block = BlockBuilder(f.root, &f.mod);
	immutable u64 = resolveLookupName(f.mod, internIn(f.mod, "mizu.u64"), f.root);
	immutable byte_ = resolveLookupName(f.mod, internIn(f.mod, "compiler.byte"), f.root);
	immutable emit = resolveLookupName(f.mod, internIn(f.mod, "compiler.emit"), f.root);
	immutable halt = resolveLookupName(f.mod, internIn(f.mod, "mizu.halt"), f.root);

	immutable n = pushNumber(block, internIn(f.mod, "n"), byte_, 1);
	assert(comptimeEvaluate(f.mod, n, &moduleSystem!mizuSchedule)); // not a call

	// A call that is not marked comptime.
	immutable runtime = pushCall(block, internIn(f.mod, "r"), byte_, emit, (&n)[0 .. 1]);
	assert(comptimeEvaluate(f.mod, runtime, &moduleSystem!mizuSchedule));
	assert(hasComponent!Call(f.mod, runtime));

	// A `compiler.*` callee, which has its own pass.
	getOrAddComponent!Flags(f.mod, runtime).flags |= Flags.Comptime;
	assert(comptimeEvaluate(f.mod, runtime, &moduleSystem!mizuSchedule));
	assert(hasComponent!Call(f.mod, runtime));

	// `mizu.halt`, which would end the throwaway program before it started.
	EntityId[0] none;
	immutable haltCall = pushCall(block, InternedString("_"), u64, halt, none[]);
	getOrAddComponent!Flags(f.mod, haltCall).flags |= Flags.Comptime;
	assert(comptimeEvaluate(f.mod, haltCall, &moduleSystem!mizuSchedule));
	assert(hasComponent!Call(f.mod, haltCall));

	// A call whose target never resolved.
	immutable dangling = pushCommon(f.mod, f.root, InternedString("_"));
	addComponent!TypeOf(f.mod, dangling).related[0] = u64;
	addComponent!Call(f.mod, dangling).related[0] = invalidEntity;
	getOrAddComponent!Flags(f.mod, dangling).flags |= Flags.Comptime;
	assert(comptimeEvaluate(f.mod, dangling, &moduleSystem!mizuSchedule));

	assert(!diagnostics().hasErrors());
	diagnostics().clear();
}

unittest { // a module with no mizu backend loaded evaluates nothing
	import tests.pipeline_helper : makeModuleWithBuiltins;

	auto f = makeModuleWithBuiltins();
	scope(exit) freeModule(f.mod);
	diagnostics().clear();

	auto block = BlockBuilder(f.root, &f.mod);
	immutable byte_ = resolveLookupName(f.mod, internIn(f.mod, "compiler.byte"), f.root);
	// A zero-argument call is vacuously comptime, and nothing `mizu.*` the
	// evaluator needs exists here - so it has to bail out rather than assemble
	// a program out of `invalidEntity`s and jump the VM into it.
	immutable emitT = resolveLookupName(f.mod, internIn(f.mod, "compiler.emit_t"), f.root);
	EntityId[0] none;
	immutable call = pushCall(block, internIn(f.mod, "c"), byte_, emitT, none[]);
	getOrAddComponent!Flags(f.mod, call).flags |= Flags.Comptime;

	assert(comptimeEvaluate(f.mod, call, &moduleSystem!mizuSchedule));
	assert(hasComponent!Call(f.mod, call));
	assert(!diagnostics().hasErrors());
	diagnostics().clear();
}

unittest {
	// A jump handed a compile-time constant is still a jump. It used to be
	// assembled into the throwaway program and *run*: the VM left for
	// whatever address the constant named - 0, here - and took the compiler
	// down with it, so the crash was the compiler's rather than the compiled
	// program's. It belongs in the output instead.
	auto r = compile(
		"path : compiler.byte_pointer = \"./mizu.doir\"\n"
		~ "_ : compiler.byte = early_include(path)\n"
		~ "_ : compiler.assembler.register = compiler.assembler.begin_register_allocation()\n"
		~ "a : mizu.u64 = 0\n"
		~ "_ : mizu.u64 = mizu.jump_to(a)\n"
		~ "_ : mizu.u64 = mizu.halt()\n");
	scope(exit) freeModule(r.mod);
	assert(r.ok);
	diagnostics().clear();
}
