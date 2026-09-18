/// `opt.materializeAliases`: rewrites every reference to an alias into a
/// reference to what it aliases. Ported from opt/materialize_aliases.hpp.
module doir.pipeline.opt.materialize_aliases;

import ecrs.storage : EntityId, invalidEntity;

import fp.dynarray : daLength = length;

import doir.interface_;
import doir.module_;
import doir.pipeline.sema.sort : newRoot;

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
