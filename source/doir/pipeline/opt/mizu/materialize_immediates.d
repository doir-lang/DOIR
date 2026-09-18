/// `opt.mizu.materializeImmediates`: expands a `mizu.load_immediate` call
/// into the byte sequence that encodes the instruction. Ported from
/// opt/mizu/materialize_immediates.hpp.
module doir.pipeline.opt.mizu.materialize_immediates;

import core.stdc.stdio : snprintf;

import ecrs.storage : EntityId;

import fp.dynarray : daLength = length;

import doir.interface_;
import doir.module_;
import doir.diagnostics;
import doir.string_helpers : InternedString;

@nogc nothrow:


bool materializeImmediates(ref Module mod, EntityId subtree) @trusted {
	if (!hasComponent!Call(mod, subtree)) return true;

	immutable u64 = resolveCached(mod, "mizu.u64", 1);
	immutable byteType = resolveCached(mod, "compiler.byte", 1);
	immutable emit = resolveCached(mod, "compiler.emit", 1);
	immutable indicateYield = resolveCached(mod, "compiler.indicate_yield", 1);
	immutable loadImmediate = resolveCached(mod, "mizu.load_immediate", 1);
	immutable loadImmediateOp = resolveCached(mod, "mizu.load_immediate_op", 1);
	immutable loadUpperImmediate = resolveCached(mod, "mizu.load_upper_immediate", 1);
	immutable loadUpperImmediateOp = resolveCached(mod, "mizu.load_upper_immediate_op", 1);

	immutable function_ = resolveAlias(mod, getComponent!Call(mod, subtree).related[0]);
	if (!(function_ == loadImmediate || function_ == loadUpperImmediate)) return true;

	if (!hasComponent!FunctionInputs(mod, subtree)) {
		expectsXInputs(mod, subtree, "load_immediate", "two");
		return false;
	}

	EntityList inputs;
	scope(exit) inputs.free();
	{
		auto stored = &getComponent!FunctionInputs(mod, subtree);
		foreach (i; 0 .. daLength(stored.related))
			inputs.push(stored.related[i]);
	}
	if (inputs.length != 2) {
		expectsXInputs(mod, subtree, "load_immediate", "two");
		return false;
	}
	resolveAliases(mod, inputs.slice);

	if (!hasComponent!Number(mod, inputs[1])) {
		// TODO: It would probably be good to relax this constraint in the future
		parameterError(mod, subtree, "load_immediate", 0, " must evaluate to a numeric constant");
		return false;
	}

	immutable target = inputs[1];
	immutable uint value = cast(uint) getComponent!Number(mod, target).value;

	immutable type = getComponent!TypeOf(mod, subtree).related[0];
	removeComponent!TypeOf(mod, subtree);
	removeComponent!Call(mod, subtree);
	auto builder = attachSubblock(mod, subtree, type);
	{
		EntityId[1] opInputs = [u64];
		immutable c = function_ == loadImmediate
			? pushCall(builder, InternedString("_"), u64, loadImmediateOp, opInputs[])
			: pushCall(builder, InternedString("_"), u64, loadUpperImmediateOp, opInputs[]);
		getOrAddComponent!Flags(mod, c).flags = Flags.Inline;

		// TODO: Some sort of actual register allocation logic would be nice
		if (!hasComponent!AssignedRegister(mod, target)) {
			noAssociatedRegister(mod, subtree, target);
			return false;
		}
		immutable r = getComponent!AssignedRegister(mod, target).reg;
		getOrAddComponent!AssignedRegister(mod, subtree).reg = r;

		immutable ubyte low = cast(ubyte)(r & 0xFF);
		EntityId[1] emitInputs;
		emitInputs[0] = pushNumber(builder, internIn(mod, "low"), byteType, low);
		pushCall(builder, InternedString("_"), byteType, emit, emitInputs[]);

		immutable ubyte high = cast(ubyte)((r >> 8) & 0xFF);
		emitInputs[0] = pushNumber(builder, internIn(mod, "high"), byteType, high);
		pushCall(builder, InternedString("_"), byteType, emit, emitInputs[]);

		auto bytes = (cast(const(ubyte)*) &value)[0 .. uint.sizeof];
		foreach (i; 0 .. bytes.length) {
			char[24] buffer;
			immutable n = snprintf(buffer.ptr, buffer.length, "%%%zu", i);
			emitInputs[0] = pushNumber(builder, internIn(mod, buffer[0 .. n]), byteType, cast(int) bytes[i]);
			pushCall(builder, InternedString("_"), byteType, emit, emitInputs[]);
		}

		emitInputs[0] = pushNumber(builder, internIn(mod, "zero"), byteType, 0);
		foreach (_; 0 .. 2) // Need to fill in another uint16_t
			pushCall(builder, InternedString("_"), byteType, emit, emitInputs[]);

		EntityId[1] yieldInputs = [u64];
		pushCall(builder, InternedString("_"), u64, indicateYield, yieldInputs[]);
	}
	builder.end();
	return true;
}
