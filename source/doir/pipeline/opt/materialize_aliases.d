/// `opt.materializeAliases`: rewrites every reference to an alias into a
/// reference to what it aliases. Ported from opt/materialize_aliases.hpp.
module doir.pipeline.opt.materialize_aliases;

import ecrs.storage : EntityId, invalidEntity;

import fp.dynarray : daLength = length;

import doir.interface_;
import doir.module_;
import doir.pipeline.canon.sort : newRoot;

static import fp.dynarray;

@nogc nothrow:


bool materializeAliases(ref Module mod, EntityId subtree, EntityId root = currentCanonicalizeRoot) @trusted {
	if (!hasComponent!Alias(mod, subtree)) return true;
	if (!hasComponent!Parent(mod, subtree)) return true;
	if (root == currentCanonicalizeRoot) root = newRoot;

	auto aliasComponent = &getComponent!Alias(mod, subtree);
	if (aliasComponent.hasFile) return true; // Can't materialize aliases to other files

	immutable parent = getComponent!Parent(mod, subtree).related[0];
	immutable target = resolveAlias(mod, aliasComponent.related[0]);

	// Remember where `subtree` sits in its own block so the substitution can
	// be undone there (the alias entity itself must stay listed).
	size_t index = size_t.max;
	{
		auto block = &getComponent!Block(mod, parent);
		foreach (i; 0 .. daLength(block.related))
			if (block.related[i] == subtree) { index = i; break; }
	}

	EntityPairLiteral[1] subs = [EntityPairLiteral(subtree, target)];
	substituteEntities(mod, root, subs[]);

	if (index != size_t.max)
		getComponent!Block(mod, parent).related[index] = subtree; // Undo the substitution in the block itself

	return true;
}


// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
//
// `materializeAliases` is ported but not scheduled - the C++ mizu schedule
// has it commented out, and `doir.pipeline.mizuSchedule` keeps it that way -
// so it is driven directly here.

version (unittest) {
	import doir.pipeline.canon.sort : sort;
	import tests.pipeline_helper;
}

unittest { // every reference to an alias becomes a reference to its target
	auto f = makeModuleWithBuiltins();
	scope(exit) freeModule(f.mod);

	auto block = BlockBuilder(f.root, &f.mod);
	immutable byte_ = resolveLookupName(f.mod, internIn(f.mod, "compiler.byte"), f.root);
	immutable emit = resolveLookupName(f.mod, internIn(f.mod, "compiler.emit"), f.root);

	immutable target = pushNumber(block, internIn(f.mod, "target"), byte_, 5);
	immutable aliasE = pushAlias(block, internIn(f.mod, "shorthand"), target);
	immutable user = pushCall(block, internIn(f.mod, "user"), byte_, emit, (&aliasE)[0 .. 1]);

	assert(getComponent!FunctionInputs(f.mod, user).related[0] == aliasE);
	assert(materializeAliases(f.mod, aliasE, f.root));

	// The call now names the target directly...
	assert(getComponent!FunctionInputs(f.mod, user).related[0] == target);
	// ...while the alias entity itself is still listed in its own block, so
	// the substitution did not delete it from the tree.
	auto parent = &getComponent!Block(f.mod, getComponent!Parent(f.mod, aliasE).related[0]);
	bool stillListed = false;
	foreach (i; 0 .. daLength(parent.related))
		if (parent.related[i] == aliasE) stillListed = true;
	assert(stillListed);
}

unittest { // anything that isn't a materialisable alias is left alone
	auto f = makeModuleWithBuiltins();
	scope(exit) freeModule(f.mod);

	auto block = BlockBuilder(f.root, &f.mod);
	immutable byte_ = resolveLookupName(f.mod, internIn(f.mod, "compiler.byte"), f.root);
	immutable n = pushNumber(block, internIn(f.mod, "n"), byte_, 5);

	// No `Alias` component at all.
	assert(materializeAliases(f.mod, n, f.root));

	// An alias with no `Parent`.
	immutable orphan = addEntity(f.mod);
	addComponent!Alias(f.mod, orphan).related[0] = n;
	assert(materializeAliases(f.mod, orphan, f.root));

	// An alias that names another file cannot be materialized.
	immutable crossFile = pushAlias(block, internIn(f.mod, "elsewhere"), n);
	auto a = &getComponent!Alias(f.mod, crossFile);
	a.file = "other.doir";
	a.hasFile = true;
	assert(materializeAliases(f.mod, crossFile, f.root));
	assert(hasComponent!Alias(f.mod, crossFile));

	// An alias whose parent block no longer lists it still substitutes; there
	// is simply nothing to undo afterwards.
	immutable unlisted = pushAlias(block, internIn(f.mod, "unlisted"), n);
	auto related = &getComponent!Block(f.mod, f.root).related;
	foreach (i; 0 .. daLength(*related))
		if ((*related)[i] == unlisted) { fp.dynarray.removeAt(*related, i); break; }
	assert(materializeAliases(f.mod, unlisted, f.root));
}

unittest { // the default root is whatever `canonicalize.sort` last produced
	auto f = makeModuleWithBuiltins();
	scope(exit) freeModule(f.mod);

	auto block = BlockBuilder(f.root, &f.mod);
	immutable byte_ = resolveLookupName(f.mod, internIn(f.mod, "compiler.byte"), f.root);
	immutable target = pushNumber(block, internIn(f.mod, "target"), byte_, 5);
	immutable aliasE = pushAlias(block, internIn(f.mod, "shorthand"), target);

	immutable sorted = sort(f.mod, f.root); // republishes `newRoot`
	assert(sorted != invalidEntity);
	// Ids moved under the sort, so find the alias again by name.
	immutable moved = resolveLookupName(f.mod, internIn(f.mod, "shorthand"), sorted);
	assert(moved != invalidEntity);
	cast(void) aliasE;
	assert(materializeAliases(f.mod, moved));
}
