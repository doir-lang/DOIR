/// `canonicalize.sort`: renumbers every entity into post-order so that a
/// block's children always precede it and ids can be walked as ranges.
/// Ported from sema/canonicalize/sort.cpp.
module doir.pipeline.sema.sort;

static import fp.dynarray;
import fp.dynarray : daLength = length;

import ecrs.context : reorderEntities;
import ecrs.storage : EntityId, invalidEntity;

import doir.interface_;
import doir.module_;

@nogc nothrow:


/// The root `canonicalize.sort` most recently produced. Thread-local, as in
/// the C++ original (module-scope variables are TLS by default in D).
EntityId newRoot = invalidEntity;


/// Orders a function body's children so that its parameters come first, in
/// declaration order, and everything else keeps its id order.
///
/// An insertion sort rather than `std::sort`: blocks are short, the
/// comparator needs the module (so `qsort` is out without the non-portable
/// `qsort_r`), and being stable matches what the original's comparator
/// intends for the non-parameter tail.
private void sortParametersFirst(ref Module mod, EntityId* related, size_t count) @trusted {
	bool less(EntityId a, EntityId b) {
		immutable aIsParam = hasComponent!FunctionParameter(mod, a);
		immutable bIsParam = hasComponent!FunctionParameter(mod, b);
		if (aIsParam && bIsParam)
			return getComponent!FunctionParameter(mod, a).index < getComponent!FunctionParameter(mod, b).index;
		else if (aIsParam) return true;
		else if (bIsParam) return false;
		else return a < b;
	}

	foreach (i; 1 .. count) {
		immutable key = related[i];
		size_t j = i;
		while (j > 0 && less(key, related[j - 1])) {
			related[j] = related[j - 1];
			--j;
		}
		related[j] = key;
	}
}

private void sortTreeWalk(ref Module mod, EntityId subtree, ref EntityId* order, ref SortedEntitySet found) @trusted {
	if (found.contains(subtree)) return;
	found.insert(subtree);

	immutable functionDef = hasComponent!FunctionReturnType(mod, subtree);
	immutable functionDefLookup = hasComponent!LookupFunctionReturnType(mod, subtree);

	if (hasComponent!Block(mod, subtree)) {
		auto block = &getComponent!Block(mod, subtree);
		if (functionDef || functionDefLookup)
			sortParametersFirst(mod, block.related, daLength(block.related));

		// Re-read the block each iteration: the recursion below can add
		// components (and so reallocate the Block storage) underneath us.
		for (size_t i = 0; i < daLength(getComponent!Block(mod, subtree).related); ++i) {
			immutable e = getComponent!Block(mod, subtree).related[i];
			sortTreeWalk(mod, e, order, found);
		}
	}

	fp.dynarray.pushBack(order, subtree);
}

/// Renumbers the module so `root`'s subtree comes first in post-order,
/// followed by every entity the walk never reached. Returns (and publishes
/// as `newRoot`) the root's new id.
EntityId sort(ref Module mod, EntityId root) @trusted {
	EntityId* order = null;
	scope(exit) if (order !is null) fp.dynarray.free(order);
	fp.dynarray.pushBack(order, cast(EntityId) 0);

	SortedEntitySet found;
	scope(exit) found.free();
	found.insert(0);

	sortTreeWalk(mod, root, order, found);
	// If they aren't the same size there are duplicates in the order!
	assert(daLength(order) == found.length);

	SortedEntitySet all;
	scope(exit) all.free();
	foreach (e; 0 .. entityCount(mod))
		all.insert(cast(EntityId) e);
	if (mod.ctx.freelist !is null)
		foreach (i; 0 .. daLength(mod.ctx.freelist))
			all.remove(cast(EntityId) mod.ctx.freelist[i]);

	assert(order[daLength(order) - 1] == root);
	immutable newRootId = cast(EntityId)(daLength(order) - 1);

	// `missing` = all - found, appended after the walked entities.
	foreach (e; all.slice)
		if (!found.contains(e))
			fp.dynarray.pushBack(order, e);

	// reorderEntities wants size_t indices, not EntityId.
	size_t* widened = null;
	scope(exit) if (widened !is null) fp.dynarray.free(widened);
	fp.dynarray.growToSize(widened, daLength(order));
	foreach (i; 0 .. daLength(order))
		widened[i] = order[i];

	reorderEntities!(
		Block, Parent, Pointer, FunctionReturnType, FunctionInputs,
		Alias, TypeOf, Call, PrintAsCall, LookupFunctionReturnType,
		LookupFunctionInputs, LookupAlias, LookupTypeOf, LookupCall
	)(mod.ctx, widened[0 .. daLength(widened)]);

	// Every entity id may have just changed - any name -> entity resolution
	// this module previously cached (`resolveCached`) is now stale.
	clearResolveCache(mod);

	newRoot = newRootId;
	return newRootId;
}

/// `canonicalize.sort` packaged as a system, for use in a schedule.
bool sortSystem(ref Module mod, EntityId root = currentCanonicalizeRoot) {
	sort(mod, root == currentCanonicalizeRoot ? newRoot : root);
	return true;
}
