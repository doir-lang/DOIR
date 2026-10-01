/// `opt.pinRegisters`: records the register a `compiler.assembler.pin_register`
/// call assigns. Ported from opt/pin_registers.hpp.
module doir.pipeline.opt.pin_registers;

import ecrs.storage : EntityId, invalidEntity;

static import fp.dynarray;
import fp.dynarray : daLength = length;

import doir.interface_;
import doir.module_;
import doir.diagnostics;

@nogc nothrow:


/// `compiler.return(v)` / `compiler.yield(v)`: the value a block hands back is
/// given the block's *own* register.
///
/// That is what makes a returned value a value the body computed. An emitted
/// instruction encodes its destination as `return_register`/`yield_register`,
/// which resolves to the enclosing block's register - so a body whose result
/// comes from one instruction returns it for free, and a body with two exit
/// points (`if`) or a result computed several instructions back has no way to
/// say so at all without this. Both arms of an `if` naming their own value here
/// is exactly the two of them agreeing on one register.
///
/// Silent when the argument is a type, which is `compiler.indicate_return`'s
/// job rather than this one's.
private void pinReturnValue(ref Module mod, EntityId subtree, EntityId value) @trusted {
	value = resolveAlias(mod, value);
	if (hasComponent!TypeDefinition(mod, value)) return;

	immutable block = findParent(mod, subtree);
	if (block == invalidEntity) return;
	// Nothing to copy yet on the walk before `allocateRegisters`; the one after
	// it is where this lands.
	if (!hasComponent!AssignedRegister(mod, block)) return;

	pinThrough(mod, value, getComponent!AssignedRegister(mod, block).reg);
}

/// `value` takes `reg`, and so does whatever `value`'s own body hands back.
///
/// The relation is transitive, and a depth-first walk only carries it one level:
/// a block visited before its own register was pinned has nothing to hand down,
/// and the walk never comes back. So the chain is followed here instead, from
/// the end that knows the register. Three levels is an ordinary depth - `while`'s
/// condition block is the branch reading `execute(condition)`, which the block's
/// `yield` names, which a dispatch arm's `yield` names, which the instruction
/// that computes it names - and the count is not something the schedule should
/// have to encode.
///
/// `depth` only stops a cycle; a well-formed body has no path back to itself.
private void pinThrough(ref Module mod, EntityId value, size_t reg, size_t depth = 0) @trusted {
	enum maxDepth = 64;

	getOrAddComponent!AssignedRegister(mod, value).reg = reg;
	if (depth >= maxDepth || !hasComponent!Block(mod, value)) return;

	immutable return_ = resolveCached(mod, "compiler.return", 1);
	immutable yield = resolveCached(mod, "compiler.yield", 1);

	auto related = &getComponent!Block(mod, value).related;
	foreach (i; 0 .. daLength(*related)) {
		immutable e = (*related)[i];
		if (!hasComponent!Call(mod, e) || !hasComponent!FunctionInputs(mod, e)) continue;
		immutable callee = resolveAlias(mod, getComponent!Call(mod, e).related[0]);
		if (callee != return_ && callee != yield) continue;

		auto args = &getComponent!FunctionInputs(mod, e);
		if (daLength(args.related) == 0) continue;
		immutable inner = resolveAlias(mod, args.related[daLength(args.related) - 1]);
		if (inner == value || hasComponent!TypeDefinition(mod, inner)) continue;
		pinThrough(mod, inner, reg, depth + 1);
	}
}

bool pinRegisters(ref Module mod, EntityId subtree) @trusted {
	if (!hasComponent!Call(mod, subtree)) return true;

	immutable pinRegister = resolveCached(mod, "compiler.assembler.pin_register", 1);
	immutable return_ = resolveCached(mod, "compiler.return", 1);
	immutable yield = resolveCached(mod, "compiler.yield", 1);
	immutable function_ = resolveAlias(mod, getComponent!Call(mod, subtree).related[0]);

	if (function_ == return_ || function_ == yield) {
		if (!hasComponent!FunctionInputs(mod, subtree)) return true;
		auto args = &getComponent!FunctionInputs(mod, subtree);
		if (daLength(args.related) == 0) return true;
		// The last argument, not the first: `sema.deduceTypes` splices the
		// solution for `T` in ahead of the value it was solved from.
		pinReturnValue(mod, subtree, args.related[daLength(args.related) - 1]);
		return true;
	}

	if (function_ != pinRegister) return true;

	auto inputs = resolvedInputs(mod, subtree);
	scope(exit) fp.dynarray.free(inputs);
	if (daLength(inputs) != 3) {
		expectsXInputs(mod, subtree, "pin_register", "three");
		return true;
	}

	auto reg = comptimeNumber(mod, inputs[2]);
	if (reg.isNull) {
		// Inside a function body nothing has inlined yet, the register can be
		// a *parameter* - which is not a number until a call site substitutes
		// one, and the copy that call site gets is where this lands. Standing
		// down rather than diagnosing is what lets a convention compute which
		// register it wants: `std.functions.impl.pass_arguments` asks for
		// `a0 + i`, and both halves of that are parameters of the declaration
		// until the unroll instantiates it. The same limit on the same grounds
		// as `byte_emiter.emitCall` and `computeCompilerNamespace`'s
		// `return_register`, which also decline inside a body.
		if (findFunctionInsideOf(mod, subtree) != invalidEntity) return true;
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
