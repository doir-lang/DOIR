/// `opt.pinRegisters`: records the register a `compiler.assembler.pin_register`
/// call assigns. Ported from opt/pin_registers.hpp.
module doir.pipeline.opt.pin_registers;

import ecrs.storage : EntityId;

import fp.dynarray : daLength = length;

import doir.interface_;
import doir.module_;
import doir.diagnostics;

@nogc nothrow:


bool pinRegisters(ref Module mod, EntityId subtree) @trusted {
	if (!hasComponent!Call(mod, subtree)) return true;

	immutable pinRegister = resolveCached(mod, "compiler.assembler.pin_register", 1);
	immutable function_ = resolveAlias(mod, getComponent!Call(mod, subtree).related[0]);
	if (function_ != pinRegister) return true;

	EntityList inputs;
	scope(exit) inputs.free();
	{
		auto stored = &getComponent!FunctionInputs(mod, subtree);
		foreach (i; 0 .. daLength(stored.related))
			inputs.push(stored.related[i]);
	}
	if (inputs.length != 3) {
		expectsXInputs(mod, subtree, "pin_register", "three");
		return true;
	}
	resolveAliases(mod, inputs.slice);

	if (!hasComponent!Number(mod, inputs[2])) {
		parameterError(mod, subtree, "pin_register", 2, " must be be a numeric constant");
		return true;
	}

	immutable target = inputs[1];
	immutable r = cast(size_t) getComponent!Number(mod, inputs[2]).value;

	getOrAddComponent!AssignedRegister(mod, target).reg = r;

	return true;
}
