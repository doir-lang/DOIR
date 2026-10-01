/// `opt.stripFreestandingBlocks`: drops quoted blocks nothing refers to.
/// Ported from opt/strip_freestanding_blocks.hpp.
module doir.pipeline.canon.strip_freestanding_blocks;

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

	// Not one declared inside a function body. Unlinking leaves the block in
	// the store and reachable through whatever named it, which is all a block
	// at module scope needs - `opt.inlineFunctions` never copies module scope.
	// A body is copied, though, once per instantiation, and a block it declares
	// is part of it: `std.add`'s dispatch arms name its parameters, so arms
	// shared with the declaration name the *declaration's* parameters, which no
	// call site ever binds. Once the body has been inlined the copies are at
	// module scope like any other quoted block, and a schedule that runs this
	// pass again after `comptimeEvaluate` has consumed them takes them out then
	// - which is what `standard.mizu.doir` does.
	//
	// Leaving one behind used to emit nothing, `byte_emiter` skipping a
	// `compiler.emit` inside a function body. A body `opt.liftFunctionBodies`
	// moved out *is* emitted, so that schedule runs this pass a third time
	// after the lift, by which point the spent arms are not in a body either.
	if (findFunctionInsideOf(mod, subtree)) return true;

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

unittest {
	// ...and so is one declared inside a function body, which is not dead code
	// at all: it is part of the body, and a body is copied once per
	// instantiation. `std.add`'s dispatch arms are exactly this - quoted blocks
	// naming the function's parameters - and arms shared with the declaration
	// name parameters no call site binds.
	auto r = compile(
		"ft : type = () -> compiler.byte\n"
		~ "f : ft = {\n"
		~ "\tblk : block = {\n"
		~ "\t\t%1 : compiler.byte = 6\n"
		~ "\t}\n"
		~ "\t%2 : compiler.byte = 7\n"
		~ "\t_ : compiler.byte = compiler.indicate_return(compiler.byte)\n"
		~ "}\n");
	scope(exit) freeModule(r.mod);
	assert(r.ok);

	immutable f = find(r.mod, r.root, "f");
	assert(f != invalidEntity);
	assert(find(r.mod, f, "blk") != invalidEntity);

	bool listed = false;
	auto body_ = &getComponent!Block(r.mod, f);
	foreach (i; 0 .. daLength(body_.related))
		if (hasComponent!Name(r.mod, body_.related[i])
			&& getComponent!Name(r.mod, body_.related[i]).value.view == "blk")
			listed = true;
	assert(listed);
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
