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


// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest) {
	import tests.pipeline_helper;
}

unittest {
	// A `block`-typed block nothing refers to is dead code once the block
	// itself is not consumed, so the pass unlinks it from its parent.
	auto r = compile("blk : block = {\n\t%1 : compiler.byte = 6\n}\n");
	scope(exit) freeModule(r.mod);
	assert(r.ok);
	assert(find(r.mod, r.root, "blk") == invalidEntity);
}

unittest { // ...and an exported one is kept, because something outside may use it
	auto r = compile("export blk : block = {\n\t%1 : compiler.byte = 6\n}\n");
	scope(exit) freeModule(r.mod);
	assert(r.ok);
	assert(find(r.mod, r.root, "blk") != invalidEntity);
}

unittest { // a freestanding block whose parent is gone has nothing to unlink
	auto f = makeModuleWithBuiltins();
	scope(exit) freeModule(f.mod);

	immutable blockType = resolveLookupName(f.mod, internIn(f.mod, "block"), f.root);
	assert(blockType != invalidEntity);

	immutable orphan = addEntity(f.mod);
	addComponent!Block(f.mod, orphan);
	addComponent!TypeOf(f.mod, orphan).related[0] = blockType;
	assert(stripFreestandingBlocks(f.mod, orphan));

	// Neither does something that is not a block at all.
	assert(stripFreestandingBlocks(f.mod, blockType));
}
