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
