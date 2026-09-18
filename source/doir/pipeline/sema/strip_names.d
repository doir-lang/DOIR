/// `sema.stripNames`: drops the names of everything that isn't exported.
/// Ported from sema/strip_names.hpp.
module doir.pipeline.sema.strip_names;

import ecrs.storage : EntityId;

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
