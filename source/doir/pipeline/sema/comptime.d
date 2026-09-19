/// `sema.bubbleComptime` and its validation half: works out which values the
/// compiler can evaluate at compile time. Ported from sema/comptime.hpp.
module doir.pipeline.sema.comptime;

import ecrs.storage : EntityId, invalidEntity;

import fp.dynarray : daLength = length;
import fp.string : strFree = free, strSlice = slice;

import doir.diagnostics;
import doir.interface_;
import doir.module_;
import doir.systems : fixedPointChanged;

@nogc nothrow:


/// Bubbles compile-time awareness through calls and typed values.
///
/// NOTE: this system is fixed-point aware - it sets `fixedPointChanged`
/// whenever it flips a flag, so the driver's `fixedPoint` wrapper runs it
/// again.
bool bubbleComptime(ref Module mod, EntityId subtree) @trusted {
	if (hasComponent!Call(mod, subtree)) {
		if (!hasComponent!FunctionInputs(mod, subtree)) return true;
		if (flagsSet(mod, subtree, Flags.NoComptime)) return true;

		auto inputs = &getComponent!FunctionInputs(mod, subtree);
		bool comptime = true;
		foreach (i; 0 .. daLength(inputs.related)) {
			immutable e = inputs.related[i];
			if (!flagsSet(mod, e, Flags.Comptime)) {
				if (hasComponent!TypeDefinition(mod, e)) continue; // All types are compile time known
				comptime = false;
				break;
			}
		}

		immutable function_ = resolveAlias(mod, getComponent!Call(mod, subtree).related[0]);
		// The callee need not be a function at all - `x : type = ...` followed
		// by `y : x = x()` resolves to a type definition, which has no `TypeOf`.
		// `functionArity` is the pass that reports that; bail out quietly here
		// rather than asserting before it gets the chance.
		if (!hasComponent!TypeOf(mod, function_)) return true;
		immutable ft = resolveAlias(mod, getComponent!TypeOf(mod, function_).related[0]);
		immutable comptimeFunction = flagsSet(mod, ft, Flags.Comptime);

		immutable isComptime = flagsSet(mod, subtree, Flags.Comptime);

		if (comptime || comptimeFunction) {
			getOrAddComponent!Flags(mod, subtree).flags |= Flags.Comptime;
			if (!isComptime) fixedPointChanged() = true;
		} else if (isComptime) {
			getComponent!Flags(mod, subtree).flags &= ~cast(ushort) Flags.Comptime;
			fixedPointChanged() = true;
		}

	} else if (hasComponent!TypeOf(mod, subtree)) {
		if (flagsSet(mod, subtree, Flags.NoComptime)) return true;

		immutable type = baseType(mod, getComponent!TypeOf(mod, subtree).related[0]);

		immutable comptimeBaseType = resolveCached(mod, "compiler.comptime_base_type", 1);
		bool alwaysComptime = false;
		if (hasComponent!Call(mod, type)
			&& resolveAlias(mod, getComponent!Call(mod, type).related[0]) == comptimeBaseType)
			alwaysComptime = true;
		else if (!hasComponent!TypeDefinition(mod, type)) return true;
		else alwaysComptime = flagsSet(mod, type, Flags.AlwaysComptime);

		immutable isComptime = flagsSet(mod, subtree, Flags.Comptime);
		if (!isComptime && alwaysComptime) {
			getOrAddComponent!Flags(mod, subtree).flags |= Flags.Comptime;
			fixedPointChanged() = true;
		}
	}

	return true;
}

/// Reports a compile-time call handed a value that isn't compile-time known.
bool validateComptime(ref Module mod, EntityId subtree) @trusted {
	import core.stdc.stdio : snprintf;

	if (!hasComponent!Call(mod, subtree)) return true;
	if (!hasComponent!FunctionInputs(mod, subtree)) return true;

	auto inputs = &getComponent!FunctionInputs(mod, subtree);
	size_t nonComptimeInput = size_t.max;
	foreach (i; 0 .. daLength(inputs.related)) {
		immutable e = inputs.related[i];
		if (!flagsSet(mod, e, Flags.Comptime)) {
			if (hasComponent!TypeDefinition(mod, e)) continue; // All types are compile time known
			nonComptimeInput = i;
			break;
		}
	}

	if (nonComptimeInput != size_t.max && flagsSet(mod, subtree, Flags.Comptime)) {
		immutable registerFor = resolveCached(mod, "compiler.assembler.register_for", 1);
		// register_for is allowed to take a non comptime value for its second parameter
		if (resolveAlias(mod, getComponent!Call(mod, subtree).related[0]) == registerFor
			&& nonComptimeInput == 1) return true;

		char* name;
		scope(exit) strFree(name);
		if (hasComponent!Name(mod, subtree))
			name = text(getComponent!Name(mod, subtree).value.view);
		else {
			char[24] buffer;
			immutable n = snprintf(buffer.ptr, buffer.length, "%%%u", subtree);
			name = text(buffer[0 .. n]);
		}

		parameterError(mod, subtree, strSlice(name), nonComptimeInput,
			" is not compile time known despite being provided to a compile time call.");
		return false;
	}
	return true;
}
