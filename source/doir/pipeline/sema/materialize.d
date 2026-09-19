/// `canonicalize.materializeFunctionTypesAndParameters`: copies a function
/// type's return type onto each value of that type, and declares the
/// parameters a function body left implicit. Ported from
/// sema/canonicalize/materialize_function_types_and_parameters.hpp.
module doir.pipeline.sema.materialize;

import ecrs.storage : EntityId, invalidEntity;

import doir.interface_;
import doir.module_;

@nogc nothrow:


bool materializeFunctionTypesAndParameters(ref Module mod, EntityId subtree) @trusted {
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

	if (!hasComponent!Block(mod, subtree)) return true;

	auto declInputs = inputsOf(mod, ft);
	scope(exit) declInputs.free();

	auto parameters = associatedParameters(mod, declInputs.length, subtree);
	scope(exit) parameters.free();

	if (parameters.length == 0) {
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
