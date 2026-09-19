/// `opt.computeCompilerNamespace`: evaluates the `compiler.*` builtins into
/// the values and types they denote. Ported from
/// opt/compute_compiler_namespace.cpp.
module doir.pipeline.opt.compute_compiler_namespace;

import core.stdc.stdio : printf, stdout;

import diagnose.diagnostics : Ansi, Diagnostic, pushAnnotation;
import ecrs.storage : EntityId, invalidEntity;

static import fp.dynarray;
import fp.dynarray : daLength = length;

import doir.diagnostics;
import doir.interface_;
import doir.module_;
import doir.print : printModule;

@nogc nothrow:


/// Copies a call's (already resolved) inputs into a caller-owned list with
/// every alias followed - the C++ `inputs = doir::alias::resolve(mod, inputs)`.
private EntityList resolvedInputs(ref Module mod, EntityId subtree) @trusted {
	EntityList out_;
	auto inputs = &getComponent!FunctionInputs(mod, subtree);
	foreach (i; 0 .. daLength(inputs.related))
		out_.push(inputs.related[i]);
	resolveAliases(mod, out_.slice);
	return out_;
}

/// The `(size_bits, align_bits) -> next unique id` counter behind
/// `compiler.base_type`. A dynarray rather than the C++ function-local
/// `unordered_map`, but with the same process-wide lifetime.
private struct UniqueCounterEntry {
	size_t sizeBits, alignBits, count;
}
private __gshared UniqueCounterEntry* uniqueCounter = null;

private size_t nextUnique(size_t sizeBits, size_t alignBits) @trusted {
	foreach (i; 0 .. daLength(uniqueCounter))
		if (uniqueCounter[i].sizeBits == sizeBits && uniqueCounter[i].alignBits == alignBits)
			return uniqueCounter[i].count++;
	fp.dynarray.pushBack(uniqueCounter, UniqueCounterEntry(sizeBits, alignBits, 1));
	return 0;
}

private bool computeBaseType(ref Module mod, EntityId subtree, EntityId function_, EntityId comptimeBaseType) @trusted {
	if (!hasComponent!FunctionInputs(mod, subtree)) {
		expectsXInputs(mod, subtree, "base_type", "two");
		return false;
	}
	auto inputs = resolvedInputs(mod, subtree);
	scope(exit) inputs.free();
	if (inputs.length != 2) {
		expectsXInputs(mod, subtree, "base_type", "two");
		return false;
	}

	size_t[2] bits;
	bool valid = true;
	foreach (i; 0 .. 2) {
		auto n = comptimeNumber(mod, inputs[i]);
		if (n.isNull) {
			// TODO: It would probably be good to relax this constraint in the future
			parameterError(mod, subtree, "base_type", i, " must evaluate to a numeric constant");
			valid = false;
		} else bits[i] = cast(size_t) n.get;
	}
	if (!valid) return false;

	immutable sizeBits = bits[0];
	immutable alignBits = bits[1];
	immutable unique = nextUnique(sizeBits, alignBits);

	removeComponent!TypeOf(mod, subtree);
	addComponent!PrintAsCall(mod, subtree).related[0] = function_;
	removeComponent!Call(mod, subtree);
	// NOTE: the C++ leaves `function_inputs` in place here (its removal is
	// commented out), so this port does too.

	attachType(mod, subtree);
	auto type = &getComponent!TypeDefinition(mod, subtree);
	type.size = sizeBits;
	type.alignment = alignBits;
	type.unique = unique;
	if (function_ == comptimeBaseType)
		getOrAddComponent!Flags(mod, subtree).flags |= Flags.AlwaysComptime;

	return true;
}

private bool computePointer(ref Module mod, EntityId subtree, EntityId function_) @trusted {
	if (!hasComponent!FunctionInputs(mod, subtree)) {
		expectsXInputs(mod, subtree, "pointer", "one");
		return false;
	}
	auto inputs = resolvedInputs(mod, subtree);
	scope(exit) inputs.free();
	if (inputs.length != 1) {
		expectsXInputs(mod, subtree, "pointer", "one");
		return false;
	}
	if (!hasComponent!TypeDefinition(mod, inputs[0])) {
		parameterError(mod, subtree, "pointer", 0, " must evaluate to a type");
		return false;
	}

	removeComponent!TypeOf(mod, subtree);
	removeComponent!Call(mod, subtree);
	removeComponent!FunctionInputs(mod, subtree);

	attachPointer(mod, subtree, inputs[0]);
	return true;
}

/// `compiler.always_inline` / `compiler.always_comptime`: mark the type and
/// collapse the call into an alias to it.
private bool computeTypeMarker(ref Module mod, EntityId subtree, EntityId function_,
	const(char)[] name, ushort flag) @trusted
{
	if (!hasComponent!FunctionInputs(mod, subtree)) {
		expectsXInputs(mod, subtree, name, "one");
		return false;
	}
	auto inputs = resolvedInputs(mod, subtree);
	scope(exit) inputs.free();
	if (inputs.length != 1) {
		expectsXInputs(mod, subtree, name, "one");
		return false;
	}
	if (!hasComponent!TypeDefinition(mod, inputs[0])) {
		parameterError(mod, subtree, name, 0, " must evaluate to a type");
		return false;
	}

	immutable type = inputs[0];
	getOrAddComponent!Flags(mod, type).flags |= flag;

	removeComponent!TypeOf(mod, subtree);
	addComponent!PrintAsCall(mod, subtree).related[0] = function_;
	removeComponent!Call(mod, subtree);
	removeComponent!FunctionInputs(mod, subtree);

	attachAlias(mod, subtree, type);
	return true;
}

/// `compiler.bitwise_and` / `compiler.shift_right`, folded at compile time.
///
/// The fold is recorded as a `ComptimeNumber` left on the call rather than by
/// replacing the call with a `Number`: a `Number` would make the entity *be*
/// that constant, and the entity is a call, so the swap had to take the `Call`
/// with it and put a `PrintAsCall` back in its place just to keep the printed
/// form. A `ComptimeNumber` says only that the compiler knows what the call
/// works out to - which is all this pass ever learned - and leaves the IR
/// alone, so `verify.structure` still sees exactly one value component and the
/// pass can run again over its own output (`mizu`'s schedule runs it twice).
private bool computeBinaryFold(ref Module mod, EntityId subtree,
	const(char)[] name, const(char)[] arity, bool isShift) @trusted
{
	if (findFunctionInsideOf(mod, subtree))
		return true;

	if (!hasComponent!FunctionInputs(mod, subtree)) {
		expectsXInputs(mod, subtree, name, arity);
		return false;
	}
	auto inputs = resolvedInputs(mod, subtree);
	scope(exit) inputs.free();
	if (inputs.length != 2) {
		expectsXInputs(mod, subtree, name, arity);
		return false;
	}

	size_t[2] operands;
	bool valid = true;
	foreach (i; 0 .. 2) {
		auto n = comptimeNumber(mod, inputs[i]);
		if (n.isNull) {
			parameterError(mod, subtree, name, i, " must evaluate to a numeric constant");
			valid = false;
		} else operands[i] = cast(size_t) n.get;
	}
	if (!valid) return false;

	immutable v = operands[0];
	immutable rhs = operands[1];

	getOrAddComponent!ComptimeNumber(mod, subtree).value = isShift ? (v >> rhs) : (v & rhs);

	return true;
}

/// `compiler.assembler.register_for` / `.yield_register`: the register `target`
/// was assigned, left on the call as a `ComptimeNumber` for the same reasons
/// `computeBinaryFold` does. Rerunning it is how the second
/// `computeCompilerNamespace` pass picks up a register assigned since the
/// first, so the answer is overwritten rather than added once.
private bool computeRegisterFor(ref Module mod, EntityId subtree, EntityId target,
	bool forceRegisterValues)
{
	target = resolveAlias(mod, target);
	if (hasComponent!FunctionParameter(mod, target))
		return true;

	immutable r = hasComponent!AssignedRegister(mod, target)
		? getComponent!AssignedRegister(mod, target).reg : 0;
	getOrAddComponent!ComptimeNumber(mod, subtree).value = r;
	return true;
}

bool computeCompilerNamespace(ref Module mod, EntityId subtree, bool forceRegisterValues) @trusted {
	if (!hasComponent!Call(mod, subtree)) return true;

	immutable pointer = resolveCached(mod, "compiler.pointer", 1);
	immutable baseTypeE = resolveCached(mod, "compiler.base_type", 1);
	immutable comptimeBaseType = resolveCached(mod, "compiler.comptime_base_type", 1);
	immutable bitwiseAnd = resolveCached(mod, "compiler.bitwise_and", 1);
	immutable shiftRight = resolveCached(mod, "compiler.shift_right", 1);
	immutable debugPrint = resolveCached(mod, "compiler.debug_print", 1);
	immutable alwaysInline = resolveCached(mod, "compiler.always_inline", 1);
	immutable alwaysComptime = resolveCached(mod, "compiler.always_comptime", 1);
	immutable assemblerRegisterFor = resolveCached(mod, "compiler.assembler.register_for", 1);
	immutable assemblerReturnRegister = resolveCached(mod, "compiler.assembler.return_register", 1);
	immutable assemblerYieldRegister = resolveCached(mod, "compiler.assembler.yield_register", 1);

	immutable compilerCurrentEntity = resolveCached(mod, "compiler.current_entity", 1, true);
	getComponent!Number(mod, compilerCurrentEntity).value = subtree;

	immutable function_ = resolveAlias(mod, getComponent!Call(mod, subtree).related[0]);

	if (function_ == baseTypeE || function_ == comptimeBaseType)
		return computeBaseType(mod, subtree, function_, comptimeBaseType);

	if (function_ == alwaysInline)
		return computeTypeMarker(mod, subtree, alwaysInline, "always_inline", Flags.Inline);

	if (function_ == alwaysComptime)
		return computeTypeMarker(mod, subtree, alwaysComptime, "always_comptime", Flags.AlwaysComptime);

	else if (function_ == pointer)
		return computePointer(mod, subtree, pointer);

	else if (function_ == bitwiseAnd)
		return computeBinaryFold(mod, subtree, "bitwise_and", "one", false);

	else if (function_ == shiftRight)
		return computeBinaryFold(mod, subtree, "shift_right", "two", true);

	else if (function_ == debugPrint) {
		if (!hasComponent!FunctionInputs(mod, subtree)) {
			expectsXInputs(mod, subtree, "debug_print", "two");
			return false;
		}
		auto inputs = &getComponent!FunctionInputs(mod, subtree);
		if (daLength(inputs.related) != 2) {
			expectsXInputs(mod, subtree, "debug_print", "two");
			return false;
		}

		printf("%u -> ", subtree);
		printModule(stdout, mod, getComponent!FunctionInputs(mod, subtree).related[1], true, true);
		printf("\n");

	} else if (function_ == assemblerRegisterFor) {
		if (!hasComponent!FunctionInputs(mod, subtree)) {
			expectsXInputs(mod, subtree, "register_for", "two");
			return false;
		}
		auto inputs = &getComponent!FunctionInputs(mod, subtree);
		if (daLength(inputs.related) != 2) {
			expectsXInputs(mod, subtree, "register_for", "two");
			return false;
		}

		return computeRegisterFor(mod, subtree, inputs.related[1], forceRegisterValues);

	} else if (function_ == assemblerYieldRegister) {
		immutable parent = findParent(mod, subtree);
		if (hasComponent!FunctionReturnType(mod, parent)) {
			simpleCallError(mod, subtree, text("Used ", DoirAnsi.func, "yield_register", Ansi.reset,
				" in function... did you mean to use ", DoirAnsi.func, "return_register", Ansi.reset, "?"));
			return false;
		}

		return computeRegisterFor(mod, subtree, parent, forceRegisterValues);

	} else if (function_ == assemblerReturnRegister) {
		immutable func = findFunctionInsideOf(mod, subtree);
		if (func == invalidEntity) {
			simpleCallError(mod, subtree, text("Used ", DoirAnsi.func, "return_register", Ansi.reset,
				" outside of a function"));
			return false;
		}

		// TODO: Non-inlined functions aren't yet supported... can't get return register
	}

	return true;
}

/// Visitor adaptor for `doir.systems`, with `forceRegisterValues` bound at
/// compile time - the mizu schedule picks one or the other at each of its two
/// `computeCompilerNamespace` passes, and a walker's visitor is an alias, so
/// the flag may as well be a template argument.
bool computeCompilerNamespaceVisitor(bool forceRegisterValues)(ref Module mod, EntityId subtree) {
	return computeCompilerNamespace(mod, subtree, forceRegisterValues);
}


// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
// Ported from tests/spec_syntax.test.cpp.

version (unittest) {
	import tests.pipeline_helper;
}

unittest {
	// Calling a builtin compiler intrinsic through an alias still gets computed.
	// `compiler.base_type` is computed away here (into a real TypeDefinition)
	// rather than executed on the Mizu VM - which used to compare the call's
	// target entity directly, so a call reaching it through an alias was
	// silently never computed at all.
	auto r = compile(
		"n : compiler.pointer_sized = 8\n"
		~ "my_base_type : alias = compiler.base_type\n"
		~ "weird : type = my_base_type(n, n)\n");
	scope(exit) freeModule(r.mod);
	assert(r.ok);

	immutable weird = find(r.mod, r.root, "weird");
	assert(weird != invalidEntity);
	assert(hasComponent!TypeDefinition(r.mod, weird));
	assert(!hasComponent!Call(r.mod, weird));
	assert(getComponent!TypeDefinition(r.mod, weird).size == 8);
	assert(getComponent!TypeDefinition(r.mod, weird).alignment == 8);
}


// --- The `compiler.*` builtins, one at a time -------------------------------
//
// Every arity and type error below is one `sema.functionArity` (or
// `sema.validateComptime`) rejects before this pass in a real compile, so they
// are built directly. The pass resolves `compiler.current_entity` *strictly*,
// which searches forward from an entity for the block containing it - an
// invariant `canonicalize.sort` establishes - so each fixture sorts before it
// runs anything.

version (unittest) {
	import doir.pipeline.sema.sort : sort;
	import doir.string_helpers : InternedString;

	private struct ComputeFixture {
		Module mod;
		EntityId root;
		BlockBuilder block;
	}

	private ComputeFixture makeComputeFixture() {
		diagnostics().clear();
		ComputeFixture f;
		auto built = makeModuleWithBuiltins();
		f.mod = built.mod;
		f.root = built.root;
		f.block = BlockBuilder(f.root, &f.mod);
		return f;
	}

	/// Renumbers the module the way the pipeline has by the time this pass runs.
	private void canonicalize(ref ComputeFixture f) {
		f.root = sort(f.mod, f.root);
	}

	private EntityId named(ref ComputeFixture f, const(char)[] name) {
		return resolveLookupName(f.mod, internIn(f.mod, name), f.root);
	}

	private EntityId builtin(ref ComputeFixture f, const(char)[] path) {
		immutable e = resolveLookupName(f.mod, internIn(f.mod, path), f.root);
		assert(e != invalidEntity);
		return e;
	}

	/// `<callee>(args...)`, named so it can be found again after the sort.
	private EntityId pushBuiltinCall(ref ComputeFixture f, const(char)[] name,
		const(char)[] callee, const(EntityId)[] args)
	{
		immutable byte_ = builtin(f, "compiler.byte");
		return pushCall(f.block, internIn(f.mod, name), byte_, builtin(f, callee), args);
	}
}

unittest { // `compiler.base_type` rejects a call it cannot fold
	auto f = makeComputeFixture();
	scope(exit) freeModule(f.mod);

	immutable pointerSized = builtin(f, "compiler.pointer_sized");
	immutable n = pushNumber(f.block, internIn(f.mod, "n"), pointerSized, 8);
	immutable notANumber = pushValueless(f.block, internIn(f.mod, "nan"), pointerSized);

	EntityId[1] one = [n];
	EntityId[2] nonNumeric = [n, notANumber];
	pushBuiltinCall(f, "argless", "compiler.base_type", null);
	pushBuiltinCall(f, "wrong_count", "compiler.base_type", one[]);
	pushBuiltinCall(f, "bad_type", "compiler.base_type", nonNumeric[]);
	canonicalize(f);

	// `argless` has an empty inputs component rather than none, so it is the
	// count check that catches it; stripping the component reaches the other.
	immutable argless = named(f, "argless");
	removeComponent!FunctionInputs(f.mod, argless);
	assert(!computeCompilerNamespace(f.mod, argless, false));
	assert(!computeCompilerNamespace(f.mod, named(f, "wrong_count"), false));
	assert(!computeCompilerNamespace(f.mod, named(f, "bad_type"), false));
	assert(diagnostics().hasErrors());
	diagnostics().clear();
}

unittest { // `compiler.base_type` takes sizes the compiler only worked out
	auto f = makeComputeFixture();
	scope(exit) freeModule(f.mod);

	immutable pointerSized = builtin(f, "compiler.pointer_sized");
	immutable n = pushNumber(f.block, internIn(f.mod, "n"), pointerSized, 4);
	// A folded `compiler.shift_right(n, n)` - still a call, with what it comes
	// to alongside it - is as good a size as a literal.
	EntityId[2] shiftArgs = [n, n];
	pushBuiltinCall(f, "size", "compiler.shift_right", shiftArgs[]);
	canonicalize(f);

	immutable size = named(f, "size");
	assert(computeCompilerNamespace(f.mod, size, false));
	assert(getComponent!ComptimeNumber(f.mod, size).value == 0);
	getComponent!ComptimeNumber(f.mod, size).value = 32;

	EntityId[2] args = [size, size];
	immutable t = pushBuiltinCall(f, "t", "compiler.base_type", args[]);
	assert(computeCompilerNamespace(f.mod, t, false));
	assert(hasComponent!TypeDefinition(f.mod, t));
	assert(getComponent!TypeDefinition(f.mod, t).size == 32);
	assert(getComponent!TypeDefinition(f.mod, t).alignment == 32);
	assert(!diagnostics().hasErrors());
	diagnostics().clear();
}

unittest { // `compiler.comptime_base_type` marks what it builds always-comptime
	auto f = makeComputeFixture();
	scope(exit) freeModule(f.mod);

	immutable pointerSized = builtin(f, "compiler.pointer_sized");
	immutable n = pushNumber(f.block, internIn(f.mod, "n"), pointerSized, 16);
	EntityId[2] args = [n, n];
	pushBuiltinCall(f, "t", "compiler.comptime_base_type", args[]);
	canonicalize(f);

	immutable t = named(f, "t");
	assert(computeCompilerNamespace(f.mod, t, false));
	assert(hasComponent!TypeDefinition(f.mod, t));
	assert(getComponent!TypeDefinition(f.mod, t).size == 16);
	assert(flagsSet(f.mod, t, Flags.AlwaysComptime));
	assert(!diagnostics().hasErrors());
	diagnostics().clear();
}

unittest { // `compiler.pointer` turns a type into a pointer to it
	auto f = makeComputeFixture();
	scope(exit) freeModule(f.mod);

	immutable byte_ = builtin(f, "compiler.byte");
	immutable type = builtin(f, "type");
	immutable n = pushNumber(f.block, internIn(f.mod, "n"),
		builtin(f, "compiler.pointer_sized"), 1);

	EntityId[1] typeArg = [type];
	EntityId[2] two = [type, type];
	EntityId[1] notAType = [n];
	pushBuiltinCall(f, "p", "compiler.pointer", typeArg[]);
	pushBuiltinCall(f, "argless", "compiler.pointer", typeArg[]);
	pushBuiltinCall(f, "wrong_count", "compiler.pointer", two[]);
	pushBuiltinCall(f, "bad_type", "compiler.pointer", notAType[]);
	canonicalize(f);

	immutable p = named(f, "p");
	assert(computeCompilerNamespace(f.mod, p, false));
	assert(hasComponent!Pointer(f.mod, p));
	assert(!hasComponent!Call(f.mod, p));
	assert(!diagnostics().hasErrors());

	immutable argless = named(f, "argless");
	removeComponent!FunctionInputs(f.mod, argless);
	assert(!computeCompilerNamespace(f.mod, argless, false));
	assert(!computeCompilerNamespace(f.mod, named(f, "wrong_count"), false));
	assert(!computeCompilerNamespace(f.mod, named(f, "bad_type"), false));
	assert(diagnostics().hasErrors());
	diagnostics().clear();
	cast(void) byte_;
}

unittest { // `always_inline` and `always_comptime` mark the type they are given
	static immutable string[2] callees = ["compiler.always_inline", "compiler.always_comptime"];
	static immutable ushort[2] flags = [Flags.Inline, Flags.AlwaysComptime];

	foreach (i, callee; callees) {
		auto f = makeComputeFixture();
		scope(exit) freeModule(f.mod);

		immutable type = builtin(f, "type");
		immutable n = pushNumber(f.block, internIn(f.mod, "n"),
			builtin(f, "compiler.pointer_sized"), 1);

		EntityId[1] typeArg = [type];
		EntityId[2] two = [type, type];
		EntityId[1] notAType = [n];
		pushBuiltinCall(f, "marked", callee, typeArg[]);
		pushBuiltinCall(f, "argless", callee, typeArg[]);
		pushBuiltinCall(f, "wrong_count", callee, two[]);
		pushBuiltinCall(f, "bad_type", callee, notAType[]);
		canonicalize(f);

		immutable marked = named(f, "marked");
		assert(computeCompilerNamespace(f.mod, marked, false));
		assert(hasComponent!Alias(f.mod, marked)); // collapsed into an alias to the type
		assert(flagsSet(f.mod, named(f, "type"), flags[i]));
		assert(!diagnostics().hasErrors());

		immutable argless = named(f, "argless");
		removeComponent!FunctionInputs(f.mod, argless);
		assert(!computeCompilerNamespace(f.mod, argless, false));
		assert(!computeCompilerNamespace(f.mod, named(f, "wrong_count"), false));
		assert(!computeCompilerNamespace(f.mod, named(f, "bad_type"), false));
		assert(diagnostics().hasErrors());
		diagnostics().clear();
	}
}

unittest { // `bitwise_and` and `shift_right` fold their two constants
	static immutable string[2] callees = ["compiler.bitwise_and", "compiler.shift_right"];
	// `0b1100 & 0b0110 == 0b0100`, and `0b1100 >> 2 == 0b0011`.
	static immutable size_t[2] rhsValues = [0b0110, 2];
	static immutable size_t[2] expected = [0b0100, 0b0011];

	foreach (i, callee; callees) {
		auto f = makeComputeFixture();
		scope(exit) freeModule(f.mod);

		immutable pointerSized = builtin(f, "compiler.pointer_sized");
		immutable lhs = pushNumber(f.block, internIn(f.mod, "lhs"), pointerSized, 0b1100);
		immutable rhs = pushNumber(f.block, internIn(f.mod, "rhs"), pointerSized, rhsValues[i]);
		immutable notANumber = pushValueless(f.block, internIn(f.mod, "nan"), pointerSized);

		EntityId[2] args = [lhs, rhs];
		EntityId[1] one = [lhs];
		EntityId[2] nonNumeric = [lhs, notANumber];
		pushBuiltinCall(f, "folded", callee, args[]);
		pushBuiltinCall(f, "argless", callee, args[]);
		pushBuiltinCall(f, "wrong_count", callee, one[]);
		pushBuiltinCall(f, "bad_type", callee, nonNumeric[]);
		canonicalize(f);

		// The call stays put; what the fold learned rides along beside it.
		immutable folded = named(f, "folded");
		assert(computeCompilerNamespace(f.mod, folded, false));
		assert(hasComponent!Call(f.mod, folded));
		assert(!hasComponent!Number(f.mod, folded));
		assert(cast(size_t) getComponent!ComptimeNumber(f.mod, folded).value == expected[i]);
		assert(!diagnostics().hasErrors());

		immutable argless = named(f, "argless");
		removeComponent!FunctionInputs(f.mod, argless);
		assert(!computeCompilerNamespace(f.mod, argless, false));
		assert(!computeCompilerNamespace(f.mod, named(f, "wrong_count"), false));
		assert(!computeCompilerNamespace(f.mod, named(f, "bad_type"), false));
		assert(diagnostics().hasErrors());
		diagnostics().clear();
	}
}

unittest { // `compiler.debug_print` renders its second argument
	auto f = makeComputeFixture();
	scope(exit) freeModule(f.mod);

	immutable type = builtin(f, "type");
	immutable n = pushNumber(f.block, internIn(f.mod, "n"),
		builtin(f, "compiler.pointer_sized"), 1);

	EntityId[2] args = [type, n];
	EntityId[1] one = [n];
	pushBuiltinCall(f, "printed", "compiler.debug_print", args[]);
	pushBuiltinCall(f, "argless", "compiler.debug_print", args[]);
	pushBuiltinCall(f, "wrong_count", "compiler.debug_print", one[]);
	canonicalize(f);

	assert(computeCompilerNamespace(f.mod, named(f, "printed"), false));
	assert(!diagnostics().hasErrors());

	immutable argless = named(f, "argless");
	removeComponent!FunctionInputs(f.mod, argless);
	assert(!computeCompilerNamespace(f.mod, argless, false));
	assert(!computeCompilerNamespace(f.mod, named(f, "wrong_count"), false));
	assert(diagnostics().hasErrors());
	diagnostics().clear();
}

unittest { // `register_for` reports the register its target was assigned
	auto f = makeComputeFixture();
	scope(exit) freeModule(f.mod);

	immutable type = builtin(f, "type");
	immutable pointerSized = builtin(f, "compiler.pointer_sized");
	immutable target = pushNumber(f.block, internIn(f.mod, "target"), pointerSized, 1);
	getOrAddComponent!AssignedRegister(f.mod, target).reg = 9;
	immutable unassigned = pushNumber(f.block, internIn(f.mod, "unassigned"), pointerSized, 1);

	EntityId[2] args = [type, target];
	EntityId[2] unassignedArgs = [type, unassigned];
	EntityId[1] one = [type];
	pushBuiltinCall(f, "r", "compiler.assembler.register_for", args[]);
	pushBuiltinCall(f, "no_reg", "compiler.assembler.register_for", unassignedArgs[]);
	pushBuiltinCall(f, "argless", "compiler.assembler.register_for", args[]);
	pushBuiltinCall(f, "wrong_count", "compiler.assembler.register_for", one[]);
	canonicalize(f);

	immutable r = named(f, "r");
	assert(computeCompilerNamespace(f.mod, r, false));
	assert(hasComponent!Call(f.mod, r));
	assert(!hasComponent!Number(f.mod, r));
	assert(getComponent!ComptimeNumber(f.mod, r).value == 9);

	// A target with no register yet reads as register 0.
	immutable noReg = named(f, "no_reg");
	assert(computeCompilerNamespace(f.mod, noReg, false));
	assert(getComponent!ComptimeNumber(f.mod, noReg).value == 0);
	assert(!diagnostics().hasErrors());

	// The call is still a call, so the pass can run over it again - which is
	// how the second `computeCompilerNamespace` pass picks up a register
	// assigned since the first rather than being locked out by its own answer.
	getComponent!AssignedRegister(f.mod, named(f, "target")).reg = 4;
	assert(computeCompilerNamespace(f.mod, r, true));
	assert(getComponent!ComptimeNumber(f.mod, r).value == 4);

	immutable argless = named(f, "argless");
	removeComponent!FunctionInputs(f.mod, argless);
	assert(!computeCompilerNamespace(f.mod, argless, false));
	assert(!computeCompilerNamespace(f.mod, named(f, "wrong_count"), false));
	assert(diagnostics().hasErrors());
	diagnostics().clear();
}

unittest { // a `register_for` whose target is a parameter is left for later
	auto f = makeComputeFixture();
	scope(exit) freeModule(f.mod);

	immutable type = builtin(f, "type");
	immutable byte_ = builtin(f, "compiler.byte");
	Lookup[1] inputs = [Lookup(byte_)];
	InternedString[1] names = [internIn(f.mod, "p")];
	immutable ft = pushFunctionType(f.block, internIn(f.mod, "ft"), inputs[], Lookup(byte_), true, names[]);
	auto fb = pushFunction(f.block, internIn(f.mod, "fn"), ft, true);
	immutable parameter = getComponent!Block(f.mod, fb.builder.block).related[0];
	assert(hasComponent!FunctionParameter(f.mod, parameter));

	EntityId[2] args = [type, parameter];
	pushBuiltinCall(f, "r", "compiler.assembler.register_for", args[]);
	canonicalize(f);

	immutable r = named(f, "r");
	assert(computeCompilerNamespace(f.mod, r, false));
	assert(hasComponent!Call(f.mod, r)); // untouched
	assert(!diagnostics().hasErrors());
	diagnostics().clear();
}

unittest { // `yield_register` is for a block, not a function
	auto f = makeComputeFixture();
	scope(exit) freeModule(f.mod);

	immutable byte_ = builtin(f, "compiler.byte");
	// A function type built from resolved parameter entities gives the function
	// a resolved `FunctionReturnType`, which is what marks it a function here.
	EntityId[0] resolvedInputs;
	immutable ft = pushFunctionType(f.block, internIn(f.mod, "ft"), resolvedInputs[],
		cast(EntityId) byte_, true);
	auto fb = pushFunction(f.block, internIn(f.mod, "fn"), ft);
	assert(hasComponent!FunctionReturnType(f.mod, fb.builder.block));
	pushCall(fb.builder, internIn(f.mod, "inside"), byte_,
		builtin(f, "compiler.assembler.yield_register"), resolvedInputs[0 .. 0]);

	// ...and outside one it reports the enclosing block's register.
	pushBuiltinCall(f, "outside", "compiler.assembler.yield_register", null);
	canonicalize(f);

	immutable fn = named(f, "fn");
	immutable inside = getComponent!Block(f.mod, fn).related[0];
	assert(!computeCompilerNamespace(f.mod, inside, false));
	assert(diagnostics().hasErrors());
	diagnostics().clear();

	immutable outside = named(f, "outside");
	assert(computeCompilerNamespace(f.mod, outside, false));
	assert(hasComponent!ComptimeNumber(f.mod, outside));
	assert(!diagnostics().hasErrors());
	diagnostics().clear();
}

unittest { // `return_register` is the other way round: it needs a function
	auto f = makeComputeFixture();
	scope(exit) freeModule(f.mod);

	immutable byte_ = builtin(f, "compiler.byte");
	EntityId[0] resolvedInputs;
	immutable ft = pushFunctionType(f.block, internIn(f.mod, "ft"), resolvedInputs[],
		cast(EntityId) byte_, true);
	auto fb = pushFunction(f.block, internIn(f.mod, "fn"), ft);
	pushCall(fb.builder, internIn(f.mod, "inside"), byte_,
		builtin(f, "compiler.assembler.return_register"), resolvedInputs[0 .. 0]);

	pushBuiltinCall(f, "outside", "compiler.assembler.return_register", null);
	canonicalize(f);

	// Inside a function it is accepted (and, for now, does nothing)...
	immutable fn = named(f, "fn");
	immutable inside = getComponent!Block(f.mod, fn).related[0];
	assert(computeCompilerNamespace(f.mod, inside, false));
	assert(!diagnostics().hasErrors());

	// ...and outside one it is an error.
	assert(!computeCompilerNamespace(f.mod, named(f, "outside"), false));
	assert(diagnostics().hasErrors());
	diagnostics().clear();
}

unittest { // anything that is not a `compiler.*` call is left alone
	auto f = makeComputeFixture();
	scope(exit) freeModule(f.mod);

	immutable byte_ = builtin(f, "compiler.byte");
	immutable n = pushNumber(f.block, internIn(f.mod, "n"), byte_, 1);
	pushBuiltinCall(f, "emitted", "compiler.emit", (&n)[0 .. 1]);
	canonicalize(f);

	assert(computeCompilerNamespace(f.mod, named(f, "n"), false)); // not a call
	immutable emitted = named(f, "emitted");
	assert(computeCompilerNamespace(f.mod, emitted, false));
	assert(hasComponent!Call(f.mod, emitted));
	assert(!diagnostics().hasErrors());
	diagnostics().clear();
}
