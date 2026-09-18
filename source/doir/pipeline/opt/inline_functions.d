/// `opt.inlineFunctions`: replaces a call to an inline-marked function with a
/// copy of its body. Ported from opt/inline_functions.cpp.
module doir.pipeline.opt.inline_functions;

import core.stdc.stdio : snprintf;

import ecrs.storage : EntityId, invalidEntity;

static import fp.dynarray;
import fp.dynarray : daLength = length;

import doir.interface_;
import doir.module_;
import doir.string_helpers : InternedString;

@nogc nothrow:


bool inlineFunctions(ref Module mod, EntityId subtree) @trusted {
	if (!hasComponent!Call(mod, subtree)) return true;

	immutable functionDef = resolveAlias(mod, getComponent!Call(mod, subtree).related[0]);
	immutable ft = getComponent!TypeOf(mod, functionDef).related[0];
	if (!(flagsSet(mod, ft, Flags.Inline) || flagsSet(mod, subtree, Flags.Inline)))
		return true;

	removeComponent!Call(mod, subtree);

	// Snapshot the arguments before the component goes away.
	EntityList inputs;
	scope(exit) inputs.free();
	{
		auto stored = &getComponent!FunctionInputs(mod, subtree);
		foreach (i; 0 .. daLength(stored.related))
			inputs.push(stored.related[i]);
	}
	removeComponent!FunctionInputs(mod, subtree);

	auto params = associatedParameters(mod, inputs.length, functionDef);
	scope(exit) params.free();

	addComponent!Block(mod, subtree);
	auto block = BlockBuilder(subtree, &mod);

	EntityMap paramReplacements;
	scope(exit) paramReplacements.free();
	foreach (i; 0 .. inputs.length) {
		InternedString name;
		if (hasComponent!Name(mod, params[i]))
			name = getComponent!Name(mod, params[i]).value;
		else {
			char[24] buffer;
			immutable n = snprintf(buffer.ptr, buffer.length, "a%zu", i);
			name = internIn(mod, buffer[0 .. n]);
		}
		paramReplacements.set(params[i], pushAlias(block, name, inputs[i]));
	}

	auto source = BlockBuilder(functionDef, &mod);
	copyExisting(block, source, true);
	substituteEntities(mod, subtree, paramReplacements);

	immutable indicateReturn = resolveLookupName(mod, internIn(mod, "compiler.indicate_return"), 1);
	immutable indicateYield = resolveLookupName(mod, internIn(mod, "compiler.indicate_yield"), 1);
	immutable returnRegister = resolveLookupName(mod, internIn(mod, "compiler.assembler.return_register"), 1);
	immutable yieldRegister = resolveLookupName(mod, internIn(mod, "compiler.assembler.yield_register"), 1);
	// TODO: Does this fix recursive issues? TODO: Calls to return should become calls to yield
	EntityPairLiteral[2] returnSubs = [
		EntityPairLiteral(indicateReturn, indicateYield),
		EntityPairLiteral(returnRegister, yieldRegister),
	];
	substituteEntities(mod, subtree, returnSubs[], 1);

	ushort flags = 0;
	if (flagsSet(mod, subtree, Flags.Export)) flags |= Flags.Export;
	if (flagsSet(mod, subtree, Flags.Flatten)) flags |= Flags.Flatten;
	getOrAddComponent!Flags(mod, subtree).flags = flags;

	return true;
}
