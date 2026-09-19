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


// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest) {
	import doir.string_helpers : InternedString;
	import doir.systems : fixedPointChanged;
	import tests.pipeline_helper;
}

unittest {
	// A call whose arguments are all compile-time known is itself compile-time
	// known; one handed a runtime value is not, unless the function it calls is
	// marked comptime.
	auto f = makeModuleWithBuiltins();
	scope(exit) freeModule(f.mod);
	diagnostics().clear();

	auto block = BlockBuilder(f.root, &f.mod);
	immutable byte_ = resolveLookupName(f.mod, internIn(f.mod, "compiler.byte"), f.root);
	immutable indicateReturn = resolveLookupName(f.mod,
		internIn(f.mod, "compiler.indicate_return"), f.root);
	assert(indicateReturn != invalidEntity);
	// `return_t` carries no `Comptime` flag, so the call's own comptime-ness
	// follows its arguments rather than the callee.
	assert(!flagsSet(f.mod, resolveLookupName(f.mod, internIn(f.mod, "compiler.return_t"), f.root),
		Flags.Comptime));

	immutable runtime = pushValueless(block, internIn(f.mod, "runtime"), byte_);
	assert(!flagsSet(f.mod, runtime, Flags.Comptime));

	immutable call = pushCall(block, internIn(f.mod, "c"), byte_, indicateReturn,
		(&runtime)[0 .. 1]);
	// Pretend an earlier round had marked it comptime, so this one has to
	// clear the flag again and ask for another round.
	getOrAddComponent!Flags(f.mod, call).flags |= Flags.Comptime;
	fixedPointChanged() = false;

	assert(bubbleComptime(f.mod, call));
	assert(!flagsSet(f.mod, call, Flags.Comptime));
	assert(fixedPointChanged());
	fixedPointChanged() = false;
	diagnostics().clear();
}

unittest { // a type argument counts as compile-time known whatever else it is
	auto f = makeModuleWithBuiltins();
	scope(exit) freeModule(f.mod);
	diagnostics().clear();

	auto block = BlockBuilder(f.root, &f.mod);
	immutable byte_ = resolveLookupName(f.mod, internIn(f.mod, "compiler.byte"), f.root);
	immutable indicateReturn = resolveLookupName(f.mod,
		internIn(f.mod, "compiler.indicate_return"), f.root);

	// `compiler.return_t` is a `TypeDefinition` that is not itself flagged
	// comptime, so the loop skips over it and the call stays comptime.
	// (`compiler.byte` would not do: it is a *call* to `base_type`, not a
	// type definition, so it counts as an ordinary runtime value here.)
	immutable returnT = resolveLookupName(f.mod, internIn(f.mod, "compiler.return_t"), f.root);
	assert(hasComponent!TypeDefinition(f.mod, returnT));
	assert(!flagsSet(f.mod, returnT, Flags.Comptime));

	immutable call = pushCall(block, internIn(f.mod, "c"), byte_, indicateReturn,
		(&returnT)[0 .. 1]);
	assert(bubbleComptime(f.mod, call));
	assert(flagsSet(f.mod, call, Flags.Comptime));
	fixedPointChanged() = false;
	diagnostics().clear();
}

unittest { // a compile-time call handed a runtime value is reported
	auto f = makeModuleWithBuiltins();
	scope(exit) freeModule(f.mod);
	diagnostics().clear();

	auto block = BlockBuilder(f.root, &f.mod);
	immutable byte_ = resolveLookupName(f.mod, internIn(f.mod, "compiler.byte"), f.root);
	immutable emit = resolveLookupName(f.mod, internIn(f.mod, "compiler.emit"), f.root);

	immutable runtime = pushValueless(block, internIn(f.mod, "runtime"), byte_);
	immutable named = pushCall(block, internIn(f.mod, "named"), byte_, emit, (&runtime)[0 .. 1]);
	getOrAddComponent!Flags(f.mod, named).flags |= Flags.Comptime;

	assert(!validateComptime(f.mod, named));
	assert(diagnostics().hasErrors());
	diagnostics().clear();

	// The same, on an entity with no name of its own: the message falls back
	// to `%id`.
	immutable anonymous = pushCall(block, InternedString("_"), byte_, emit, (&runtime)[0 .. 1]);
	getOrAddComponent!Flags(f.mod, anonymous).flags |= Flags.Comptime;
	assert(!hasComponent!Name(f.mod, anonymous));
	assert(!validateComptime(f.mod, anonymous));
	assert(diagnostics().hasErrors());
	diagnostics().clear();
}

unittest {
	// `compiler.assembler.register_for` is the one exception: its *second*
	// argument is allowed to be a runtime value.
	auto f = makeModuleWithBuiltins();
	scope(exit) freeModule(f.mod);
	diagnostics().clear();

	auto block = BlockBuilder(f.root, &f.mod);
	immutable byte_ = resolveLookupName(f.mod, internIn(f.mod, "compiler.byte"), f.root);
	immutable registerFor = resolveLookupName(f.mod,
		internIn(f.mod, "compiler.assembler.register_for"), f.root);
	assert(registerFor != invalidEntity);

	immutable returnT = resolveLookupName(f.mod, internIn(f.mod, "compiler.return_t"), f.root);
	immutable runtime = pushValueless(block, internIn(f.mod, "runtime"), byte_);
	EntityId[2] args = [returnT, runtime]; // the *second* argument is the runtime one
	immutable call = pushCall(block, internIn(f.mod, "c"), byte_, registerFor, args[]);
	getOrAddComponent!Flags(f.mod, call).flags |= Flags.Comptime;

	assert(validateComptime(f.mod, call));
	assert(!diagnostics().hasErrors());
	diagnostics().clear();
}

unittest { // entities neither pass has anything to say about
	auto f = makeModuleWithBuiltins();
	scope(exit) freeModule(f.mod);
	diagnostics().clear();

	auto block = BlockBuilder(f.root, &f.mod);
	immutable byte_ = resolveLookupName(f.mod, internIn(f.mod, "compiler.byte"), f.root);

	immutable bare = addEntity(f.mod);
	assert(bubbleComptime(f.mod, bare));   // neither a call nor typed
	assert(validateComptime(f.mod, bare)); // not a call

	// A call with no arguments component at all.
	immutable emit = resolveLookupName(f.mod, internIn(f.mod, "compiler.emit"), f.root);
	immutable argless = addEntity(f.mod);
	addComponent!Call(f.mod, argless).related[0] = emit;
	assert(bubbleComptime(f.mod, argless));
	assert(validateComptime(f.mod, argless));

	// Something explicitly opted out of comptime inference, on both branches.
	immutable optedOut = pushNumber(block, internIn(f.mod, "n"), byte_, 1);
	getOrAddComponent!Flags(f.mod, optedOut).flags |= Flags.NoComptime;
	assert(bubbleComptime(f.mod, optedOut));

	immutable optedOutCall = pushCall(block, internIn(f.mod, "c"), byte_, emit,
		(&optedOut)[0 .. 1]);
	getOrAddComponent!Flags(f.mod, optedOutCall).flags |= Flags.NoComptime;
	assert(bubbleComptime(f.mod, optedOutCall));

	fixedPointChanged() = false;
	diagnostics().clear();
}
