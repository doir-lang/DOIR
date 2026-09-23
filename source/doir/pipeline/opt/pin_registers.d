/// `opt.pinRegisters`: records the register a `compiler.assembler.pin_register`
/// call assigns. Ported from opt/pin_registers.hpp.
module doir.pipeline.opt.pin_registers;

import ecrs.storage : EntityId;

static import fp.dynarray;
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

	auto inputs = resolvedInputs(mod, subtree);
	scope(exit) fp.dynarray.free(inputs);
	if (daLength(inputs) != 3) {
		expectsXInputs(mod, subtree, "pin_register", "three");
		return true;
	}

	auto reg = comptimeNumber(mod, inputs[2]);
	if (reg.isNull) {
		parameterError(mod, subtree, "pin_register", 2, " must be be a numeric constant");
		return true;
	}

	immutable target = inputs[1];
	immutable r = cast(size_t) reg.get;

	getOrAddComponent!AssignedRegister(mod, target).reg = r;

	return true;
}


// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
//
// The two diagnostics below are raised on IR that `sema.functionArity` would
// have rejected first in a real compile, so this builds the calls directly
// rather than driving them through the pipeline.

version (unittest) import tests.pipeline_helper;

unittest { // a well-formed call records the register on its target
	auto f = makeModuleWithBuiltins();
	scope(exit) freeModule(f.mod);
	diagnostics().clear();

	auto block = f.openRoot();
	immutable byte_ = find(f.mod, f.root, "compiler.byte");
	immutable pinRegister = find(f.mod, f.root, "compiler.assembler.pin_register");

	immutable target = pushNumber(block, internIn(f.mod, "target"), byte_, 1);
	immutable reg = pushNumber(block, internIn(f.mod, "reg"), byte_, 7);
	EntityId[3] args = [byte_, target, reg];
	immutable call = pushCall(block, internIn(f.mod, "pin"), byte_, pinRegister, args[]);

	assert(pinRegisters(f.mod, call));
	assert(hasComponent!AssignedRegister(f.mod, target));
	assert(getComponent!AssignedRegister(f.mod, target).reg == 7);
	assert(!diagnostics().hasErrors());
	diagnostics().clear();
}

unittest { // a call with the wrong number of arguments is reported
	auto f = makeModuleWithBuiltins();
	scope(exit) freeModule(f.mod);
	diagnostics().clear();

	auto block = f.openRoot();
	immutable byte_ = find(f.mod, f.root, "compiler.byte");
	immutable pinRegister = find(f.mod, f.root, "compiler.assembler.pin_register");

	EntityId[1] args = [byte_];
	immutable call = pushCall(block, internIn(f.mod, "pin"), byte_, pinRegister, args[]);

	assert(pinRegisters(f.mod, call));
	assert(diagnostics().hasErrors());
	diagnostics().clear();
}

unittest { // a register argument the compiler only worked out still counts
	auto f = makeModuleWithBuiltins();
	scope(exit) freeModule(f.mod);
	diagnostics().clear();

	auto block = f.openRoot();
	immutable byte_ = find(f.mod, f.root, "compiler.byte");
	immutable pinRegister = find(f.mod, f.root, "compiler.assembler.pin_register");

	// What a `compiler.*` call `opt.computeCompilerNamespace` folded looks
	// like: still a call, with the value it comes to alongside it.
	immutable target = pushNumber(block, internIn(f.mod, "target"), byte_, 1);
	immutable reg = pushCall(block, internIn(f.mod, "reg"), byte_,
		resolveLookupName(f.mod, internIn(f.mod, "compiler.emit"), f.root), (&target)[0 .. 1]);
	getOrAddComponent!ComptimeNumber(f.mod, reg).value = 7;

	EntityId[3] args = [byte_, target, reg];
	immutable call = pushCall(block, internIn(f.mod, "pin"), byte_, pinRegister, args[]);

	assert(pinRegisters(f.mod, call));
	assert(getComponent!AssignedRegister(f.mod, target).reg == 7);
	assert(!diagnostics().hasErrors());
	diagnostics().clear();
}

unittest { // ...and so is one whose register argument is not a number
	auto f = makeModuleWithBuiltins();
	scope(exit) freeModule(f.mod);
	diagnostics().clear();

	auto block = f.openRoot();
	immutable byte_ = find(f.mod, f.root, "compiler.byte");
	immutable pinRegister = find(f.mod, f.root, "compiler.assembler.pin_register");

	immutable target = pushNumber(block, internIn(f.mod, "target"), byte_, 1);
	immutable notANumber = pushValueless(block, internIn(f.mod, "reg"), byte_);
	EntityId[3] args = [byte_, target, notANumber];
	immutable call = pushCall(block, internIn(f.mod, "pin"), byte_, pinRegister, args[]);

	assert(pinRegisters(f.mod, call));
	assert(!hasComponent!AssignedRegister(f.mod, target));
	assert(diagnostics().hasErrors());
	diagnostics().clear();
}

unittest { // anything that is not a call to `pin_register` is left alone
	auto f = makeModuleWithBuiltins();
	scope(exit) freeModule(f.mod);
	diagnostics().clear();

	auto block = f.openRoot();
	immutable byte_ = find(f.mod, f.root, "compiler.byte");
	immutable emit = find(f.mod, f.root, "compiler.emit");

	immutable n = pushNumber(block, internIn(f.mod, "n"), byte_, 1);
	assert(pinRegisters(f.mod, n)); // not a call

	immutable other = pushCall(block, internIn(f.mod, "e"), byte_, emit, (&n)[0 .. 1]);
	assert(pinRegisters(f.mod, other)); // a call to something else
	assert(!diagnostics().hasErrors());
	diagnostics().clear();
}
