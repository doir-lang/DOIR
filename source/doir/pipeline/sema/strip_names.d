/// `sema.stripNames`: drops the names of everything that isn't exported.
/// Ported from sema/strip_names.hpp.
module doir.pipeline.sema.strip_names;

import ecrs.storage : EntityId, invalidEntity;

import doir.interface_;
import doir.module_;

@nogc nothrow:


bool stripNames(ref Module mod, EntityId subtree) {
	if (flagsSet(mod, subtree, Flags.Export)) return true;

	if (hasComponent!Name(mod, subtree))
		removeComponent!Name(mod, subtree);
	if (hasComponent!FunctionParameterNames(mod, subtree))
		removeComponent!FunctionParameterNames(mod, subtree);

	return true;
}


// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
//
// `stripNames` is ported but not scheduled - `doir.pipeline` runs no pass
// that drops names - so it is driven directly here.

version (unittest) {
	import tests.pipeline_helper;
}

unittest { // an un-exported entity loses its name and its parameter names
	auto f = makeModuleWithBuiltins();
	scope(exit) freeModule(f.mod);

	immutable debugPrint = resolveLookupName(f.mod, internIn(f.mod, "compiler.debug_print_t"), f.root);
	assert(debugPrint != invalidEntity);
	assert(hasComponent!Name(f.mod, debugPrint));
	assert(hasComponent!FunctionParameterNames(f.mod, debugPrint));

	assert(stripNames(f.mod, debugPrint));
	assert(!hasComponent!Name(f.mod, debugPrint));
	assert(!hasComponent!FunctionParameterNames(f.mod, debugPrint));

	// Running it again on an entity that has neither is still fine.
	assert(stripNames(f.mod, debugPrint));
}

unittest { // an exported entity keeps everything
	auto f = makeModuleWithBuiltins();
	scope(exit) freeModule(f.mod);

	immutable e = resolveLookupName(f.mod, internIn(f.mod, "compiler.byte"), f.root);
	getOrAddComponent!Flags(f.mod, e).flags |= Flags.Export;

	assert(stripNames(f.mod, e));
	assert(hasComponent!Name(f.mod, e));
}
