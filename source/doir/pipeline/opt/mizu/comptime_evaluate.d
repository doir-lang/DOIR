/// `opt.mizu.comptimeEvaluate`: builds a tiny Mizu program that performs one
/// compile-time call, runs it, and lets the DOIR instructions write the
/// result back into the module. Ported from opt/mizu/comptime_evaluate.cpp.
module doir.pipeline.opt.mizu.comptime_evaluate;

import core.stdc.stdio : printf, snprintf;

import ecrs.storage : EntityId, invalidEntity;

static import fp.dynarray;
import fp.dynarray : daLength = length;

import mizu.opcode : setupEnvironment, startFromEnvironment;

import doir.byte_dumper;
import doir.interface_;
import mizu.doir_instructions : doirLookup;
import mizu.portable_format : fromPortable;
import doir.module_;
import doir.diagnostics : panic;
import doir.pipeline.sema.sort : newRoot;
import doir.string_helpers : InternedString;
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
	immutable calleeParent = findParent(mod, calledFunction);
	// Compiler functions have their own pass and shouldn't really be used
	// outside of the mizu backend.
	if (calleeParent == compiler || calleeParent == assembler) return true;

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
	immutable mizuDoirSetModule = resolveCached(mod, "mizu.doir_set_module", 1, true);
	immutable mizuDoirAttachComptimeNumberI64 =
		resolveCached(mod, "mizu.doir_attach_comptime_number_i64", 1, true);

	if (calledFunction == mizuHalt) return true;

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
		: InternedString.wildcard;
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

	printf("Comptime evaluating: %u\n", subtree);

	immutable backup = newRoot;
	newRoot = comptimeBlock.block;
	mizuSchedule(mod.ctx);
	newRoot = backup;

	ByteDumper dumper;
	scope(exit) dumper.free();
	auto bytes = interpret(dumper, mod, comptimeBlock.block);
	scope(exit) bytes.free();

	{
		auto portable = fromPortable!doirLookup(bytes.slice);
		scope(exit) if (portable.program !is null) fp.dynarray.free(portable.program);

		immutable count = daLength(portable.program);
		setupEnvironment(portable.environment, portable.program, portable.program + count);
		startFromEnvironment(portable.program, portable.environment);
	}

	return true;
}
