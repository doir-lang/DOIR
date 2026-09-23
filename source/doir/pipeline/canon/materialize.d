/// `canonicalize.materializeFunctionTypesAndParameters`: copies a function
/// type's return type onto each value of that type, and declares the
/// parameters a function body left implicit. Ported from
/// sema/canonicalize/materialize_function_types_and_parameters.hpp.
module doir.pipeline.canon.materialize;

import ecrs.storage : EntityId, invalidEntity;

static import fp.dynarray;
import fp.dynarray : daLength = length;

import doir.interface_;
import doir.module_;

@nogc nothrow:


/// Whether `ft`'s own parameter list refers to itself - `(T : type, v : T)`,
/// where `v`'s type is the parameter `T` rather than anything in scope.
private bool refersToOwnParameters(ref Module mod, EntityId ft) @trusted {
	if (!hasComponent!FunctionParameterNames(mod, ft)) return false;
	auto names = getComponent!FunctionParameterNames(mod, ft).slice;
	if (names.length == 0) return false;

	bool namesAParameter(Lookup lookup) {
		if (lookup.resolved()) return false;
		foreach (name; names)
			if (name.view == lookup.name().view) return true;
		return false;
	}

	auto inputs = inputsOf(mod, ft);
	scope(exit) fp.dynarray.free(inputs);
	foreach (i; 0 .. daLength(inputs))
		if (namesAParameter(inputs[i])) return true;

	if (hasComponent!LookupFunctionReturnType(mod, ft))
		return namesAParameter(getComponent!LookupFunctionReturnType(mod, ft).lookup);

	return false;
}

/// Gives a *standalone* function type a block holding its own parameters.
///
/// `f : (T : type, v : T) -> T = { }` works without this, because the function
/// has a body and `materializeFunctionTypesAndParameters` below fills that body
/// with the parameter declarations `v : T` then resolves against. Lift the type
/// out to a name of its own -
///
///     load_immediate_t : type = (T : type, v : T) -> T
///
/// - and there is no body left: `T` names nothing in any enclosing scope, and
/// `canon.lookupsResolved` reports "Type `T` appears to not exist". The type is
/// the same type either way, so the difference was never the language's.
///
/// Only a type that *does* refer to its own parameters gets the block. That is
/// not an optimization - a function type carrying a `Block` otherwise looks
/// like an aggregate to everything that walks types, and there is no reason to
/// make every function type in a program answer that question differently than
/// it did.
private bool materializeFunctionTypeParameters(ref Module mod, EntityId ft) @trusted {
	if (hasComponent!Block(mod, ft)) return false;
	if (!hasComponent!TypeDefinition(mod, ft)) return false;
	if (!hasAnyInputs(mod, ft)) return false;
	if (!refersToOwnParameters(mod, ft)) return false;

	addComponent!Block(mod, ft);
	getOrAddComponent!Flags(mod, ft).flags |= Flags.Freestanding;
	FunctionBuilder builder;
	builder.builder = BlockBuilder(ft, &mod);
	pushParameters(builder, ft);
	return true;
}


bool materializeFunctionTypesAndParameters(ref Module mod, EntityId subtree) @trusted {
	materializeFunctionTypeParameters(mod, subtree);

	if (!(hasComponent!TypeOf(mod, subtree) || hasComponent!LookupTypeOf(mod, subtree))) return true;

	auto lookup = typeOfLookup(mod, subtree);
	if (!lookup.resolved()) return true;

	immutable ft = resolveTypeModifications(mod, lookup.entity());
	if (ft == invalidEntity) return true;
	if (!(hasComponent!FunctionReturnType(mod, ft) || hasComponent!LookupFunctionReturnType(mod, ft)))
		return true;

	if (!(hasComponent!FunctionReturnType(mod, subtree) || hasComponent!LookupFunctionReturnType(mod, subtree))) {
		if (hasComponent!FunctionReturnType(mod, ft))
			addComponent!FunctionReturnType(mod, subtree).related[0] =
				getComponent!FunctionReturnType(mod, ft).related[0];
		if (hasComponent!LookupFunctionReturnType(mod, ft))
			addComponent!LookupFunctionReturnType(mod, subtree).lookup =
				getComponent!LookupFunctionReturnType(mod, ft).lookup;
	}

	// `-> T`, where `T` is one of the function type's own parameters. What
	// `subtree` was handed - here, or eagerly by `attachValuelessFunction` at
	// parse time - is the *name*, and `subtree` is not inside the function type,
	// so resolving it in `subtree`'s scope asks somewhere `T` has never been.
	// Resolve it against the type instead, which is where it was written. Only a
	// type carrying its own parameters can have named one, so this is inert for
	// every other declaration in the program.
	if (hasComponent!Block(mod, ft) && hasComponent!LookupFunctionReturnType(mod, subtree)) {
		auto slot = &getComponent!LookupFunctionReturnType(mod, subtree);
		if (!slot.lookup.resolved()) {
			immutable resolved = resolveLookupName(mod, slot.lookup.name(), ft);
			if (resolved != invalidEntity) slot.lookup = resolved;
		}
	}

	if (!hasComponent!Block(mod, subtree)) return true;

	auto declInputs = inputsOf(mod, ft);
	scope(exit) fp.dynarray.free(declInputs);

	auto parameters = associatedParameters(mod, daLength(declInputs), subtree);
	scope(exit) fp.dynarray.free(parameters);

	if (daLength(parameters) == 0) {
		FunctionBuilder builder;
		builder.builder = BlockBuilder(subtree, &mod);
		pushParameters(builder, ft);
	}

	return true;
}


// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest) {
	import tests.pipeline_helper;
}

unittest { // a value of a function type inherits that type's return type
	auto f = makeModuleWithBuiltins();
	scope(exit) freeModule(f.mod);

	auto block = BlockBuilder(f.root, &f.mod);
	immutable byte_ = resolveLookupName(f.mod, internIn(f.mod, "compiler.byte"), f.root);

	// A function type built from resolved parameter entities carries a
	// resolved `FunctionReturnType`; one built from names (as every builtin
	// is) carries a `LookupFunctionReturnType` instead. Both are copied.
	EntityId[1] resolvedInputs = [byte_];
	immutable resolvedFt = pushFunctionType(block, internIn(f.mod, "resolved_t"),
		resolvedInputs[], cast(EntityId) byte_, true);
	assert(hasComponent!FunctionReturnType(f.mod, resolvedFt));

	immutable value = pushCommon(f.mod, f.root, internIn(f.mod, "v"));
	addComponent!TypeOf(f.mod, value).related[0] = resolvedFt;
	assert(materializeFunctionTypesAndParameters(f.mod, value));
	assert(hasComponent!FunctionReturnType(f.mod, value));
	assert(getComponent!FunctionReturnType(f.mod, value).related[0] == byte_);

	Lookup[1] pendingInputs = [Lookup(byte_)];
	immutable pendingFt = pushFunctionType(block, internIn(f.mod, "pending_t"),
		pendingInputs[], Lookup(byte_), true);
	assert(hasComponent!LookupFunctionReturnType(f.mod, pendingFt));

	immutable other = pushCommon(f.mod, f.root, internIn(f.mod, "o"));
	addComponent!TypeOf(f.mod, other).related[0] = pendingFt;
	assert(materializeFunctionTypesAndParameters(f.mod, other));
	assert(hasComponent!LookupFunctionReturnType(f.mod, other));
}

unittest { // entities with no type, or an unresolved one, are left alone
	auto f = makeModuleWithBuiltins();
	scope(exit) freeModule(f.mod);

	immutable bare = addEntity(f.mod);
	assert(materializeFunctionTypesAndParameters(f.mod, bare));

	immutable pending = addEntity(f.mod);
	addComponent!LookupTypeOf(f.mod, pending).lookup = Lookup(internIn(f.mod, "nope"));
	assert(materializeFunctionTypesAndParameters(f.mod, pending));
	assert(!hasComponent!FunctionReturnType(f.mod, pending));

	// A type that is not a function type has no return type to copy.
	immutable plain = addEntity(f.mod);
	addComponent!TypeOf(f.mod, plain).related[0] =
		resolveLookupName(f.mod, internIn(f.mod, "compiler.byte"), f.root);
	assert(materializeFunctionTypesAndParameters(f.mod, plain));
	assert(!hasComponent!FunctionReturnType(f.mod, plain));
}
