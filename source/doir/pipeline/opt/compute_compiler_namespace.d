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

	bool valid = true;
	foreach (i; 0 .. 2)
		if (!hasComponent!Number(mod, inputs[i])) {
			// TODO: It would probably be good to relax this constraint in the future
			parameterError(mod, subtree, "base_type", i, " must evaluate to a numeric constant");
			valid = false;
		}
	if (!valid) return false;

	immutable sizeBits = cast(size_t) getComponent!Number(mod, inputs[0]).value;
	immutable alignBits = cast(size_t) getComponent!Number(mod, inputs[1]).value;
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
private bool computeBinaryFold(ref Module mod, EntityId subtree, EntityId function_,
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

	bool valid = true;
	foreach (i; 0 .. 2)
		if (!hasComponent!Number(mod, inputs[i])) {
			// TODO: It would probably be good to relax this constraint in the future
			parameterError(mod, subtree, name, i, " must evaluate to a numeric constant");
			valid = false;
		}
	if (!valid) return false;

	immutable v = cast(size_t) getComponent!Number(mod, inputs[0]).value;
	immutable rhs = cast(size_t) getComponent!Number(mod, inputs[1]).value;

	addComponent!PrintAsCall(mod, subtree).related[0] = function_;
	removeComponent!Call(mod, subtree);
	addComponent!Number(mod, subtree).value = isShift ? (v >> rhs) : (v & rhs);

	return true;
}

private bool computeRegisterFor(ref Module mod, EntityId subtree, EntityId target,
	EntityId function_, bool forceRegisterValues)
{
	immutable register = resolveCached(mod, "compiler.assembler.register", 1);
	target = resolveAlias(mod, target);
	if (hasComponent!FunctionParameter(mod, target))
		return true;

	removeComponent!TypeOf(mod, subtree);
	addComponent!PrintAsCall(mod, subtree).related[0] = function_;
	removeComponent!Call(mod, subtree);
	immutable r = hasComponent!AssignedRegister(mod, target)
		? getComponent!AssignedRegister(mod, target).reg : 0;
	attachNumber(mod, subtree, register, r);
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
		return computeBinaryFold(mod, subtree, bitwiseAnd, "bitwise_and", "one", false);

	else if (function_ == shiftRight)
		return computeBinaryFold(mod, subtree, shiftRight, "shift_right", "two", true);

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

		return computeRegisterFor(mod, subtree, inputs.related[1], assemblerRegisterFor, forceRegisterValues);

	} else if (function_ == assemblerYieldRegister) {
		immutable parent = findParent(mod, subtree);
		if (hasComponent!FunctionReturnType(mod, parent)) {
			simpleCallError(mod, subtree, text("Used ", DoirAnsi.func, "yield_register", Ansi.reset,
				" in function... did you mean to use ", DoirAnsi.func, "return_register", Ansi.reset, "?"));
			return false;
		}

		return computeRegisterFor(mod, subtree, parent, assemblerYieldRegister, forceRegisterValues);

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
