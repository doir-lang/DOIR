/// `opt.stripFreestandingBlocks`: drops quoted blocks nothing refers to.
/// Ported from opt/strip_freestanding_blocks.hpp.
module doir.pipeline.opt.strip_freestanding_blocks;

import ecrs.storage : EntityId, invalidEntity;

static import fp.dynarray;
import fp.dynarray : daLength = length;

import doir.interface_;
import doir.module_;

@nogc nothrow:


bool stripFreestandingBlocks(ref Module mod, EntityId subtree) @trusted {
	if (flagsSet(mod, subtree, Flags.Export)) return true;

	if (!hasComponent!Block(mod, subtree)) return true;
	if (!blockIsFreestanding(mod, subtree)) return true;

	immutable parent = findParent(mod, subtree);
	if (parent == invalidEntity) return true;

	auto related = &getComponent!Block(mod, parent).related;
	for (size_t i = daLength(*related); i-- > 0;)
		if ((*related)[i] == subtree)
			fp.dynarray.removeAt(*related, i);

	return true;
}
