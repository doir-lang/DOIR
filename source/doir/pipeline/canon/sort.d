/// `canonicalize.sort`: renumbers every entity into post-order so that a
/// block's children always precede it and ids can be walked as ranges.
/// Ported from sema/canonicalize/sort.cpp.
module doir.pipeline.canon.sort;

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
		Alias, TypeOf, Call, PrintAsCall, Monomorphizations, MonomorphizedFor,
		LookupFunctionReturnType,
		LookupFunctionInputs, LookupAlias, LookupTypeOf, LookupCall
	)(mod.ctx, widened[0 .. daLength(widened)]);

	// Every entity id may have just changed - any name -> entity resolution
	// this module previously cached (`resolveCached`) is now stale.
	clearResolveCache(mod);

	newRoot = newRootId;
	return newRootId;
}

/// Set while something is lowering a tree it reached from inside a walk over
/// the module - `opt.comptimeEvaluate` lowering the throwaway block it built
/// for one comptime call - and a sort would therefore renumber the module out
/// from under that walk.
///
/// A schedule is a list a program wrote, and the same list lowers the module
/// and every throwaway block the comptime evaluator builds along the way. A
/// `sort` in it means the first; there is nothing to gain from the second,
/// since the throwaway block was just built an entity at a time and is already
/// in the order it was built in.
bool sortSuspended;

/// The same flag under the name the passes that are not the sort want to ask it
/// by: whether the schedule currently running is lowering one of the comptime
/// evaluator's throwaway blocks rather than the module itself.
///
/// It is one condition, so it stays one flag. A pass that only holds over the
/// program the author wrote - `sema.typeCheck` is the example - asks here,
/// because lowering manufactures shapes such a pass would reject: a body copied
/// in by `opt.inlineFunctions` has its parameters replaced by the caller's
/// values, so a `block` parameter is a `u64` by the time it is inlined.
bool loweringThrowawayBlock() { return sortSuspended; }

/// `canonicalize.sort` packaged as a system, for use in a schedule.
bool sortSystem(ref Module mod, EntityId root = currentCanonicalizeRoot) {
	if (sortSuspended) return true;
	sort(mod, root == currentCanonicalizeRoot ? newRoot : root);
	return true;
}


// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest) {
	import doir.string_helpers : InternedString;
	import tests.pipeline_helper;
}

unittest {
	// A function body's parameters are moved to the front, in declaration
	// order, whatever order the block happened to list them in; everything
	// else keeps its id order behind them.
	auto f = makeModuleWithBuiltins();
	scope(exit) freeModule(f.mod);

	auto block = BlockBuilder(f.root, &f.mod);
	immutable byte_ = resolveLookupName(f.mod, internIn(f.mod, "compiler.byte"), f.root);
	Lookup[2] inputs = [Lookup(byte_), Lookup(byte_)];
	InternedString[2] names = [internIn(f.mod, "p0"), internIn(f.mod, "p1")];
	immutable ft = pushFunctionType(block, internIn(f.mod, "ft"), inputs[], Lookup(byte_), true, names[]);

	auto fb = pushFunction(block, internIn(f.mod, "fn"), ft);
	immutable body_ = pushNumber(fb.builder, internIn(f.mod, "body"), byte_, 1);
	// Declared out of order, and behind a non-parameter.
	pushValuelessParameter(fb, 1, names[1], byte_);
	pushValuelessParameter(fb, 0, names[0], byte_);

	auto related = &getComponent!Block(f.mod, fb.builder.block).related;
	assert(daLength(*related) == 3);
	assert((*related)[0] == body_);

	sort(f.mod, f.root);

	immutable root = newRoot;
	immutable fn = resolveLookupName(f.mod, internIn(f.mod, "fn"), root);
	auto sorted = &getComponent!Block(f.mod, fn).related;
	assert(daLength(*sorted) == 3);
	assert(hasComponent!FunctionParameter(f.mod, (*sorted)[0]));
	assert(getComponent!FunctionParameter(f.mod, (*sorted)[0]).index == 0);
	assert(hasComponent!FunctionParameter(f.mod, (*sorted)[1]));
	assert(getComponent!FunctionParameter(f.mod, (*sorted)[1]).index == 1);
	assert(!hasComponent!FunctionParameter(f.mod, (*sorted)[2]));
}

unittest { // entities on the freelist are not renumbered into the result
	auto f = makeModuleWithBuiltins();
	scope(exit) freeModule(f.mod);

	auto block = BlockBuilder(f.root, &f.mod);
	immutable byte_ = resolveLookupName(f.mod, internIn(f.mod, "compiler.byte"), f.root);
	pushNumber(block, internIn(f.mod, "kept"), byte_, 1);

	// An entity that was created and then removed: it is on the freelist, so
	// the walk must leave it out of the ordering rather than treating it as
	// an unreached entity to append.
	immutable dead = addEntity(f.mod);
	removeEntity(f.mod, dead);
	assert(entityIsFree(f.mod, dead));

	immutable root = sort(f.mod, f.root);
	assert(root != invalidEntity);
	assert(resolveLookupName(f.mod, internIn(f.mod, "kept"), root) != invalidEntity);
}

unittest { // `sortSystem` is the same thing wrapped as a schedule step
	auto f = makeModuleWithBuiltins();
	scope(exit) freeModule(f.mod);

	assert(sortSystem(f.mod, f.root));
	immutable first = newRoot;
	assert(first != invalidEntity);

	// With no root given it re-sorts whatever it last produced.
	assert(sortSystem(f.mod));
	assert(newRoot == first);
}

unittest { // `sortSuspended` makes the sort system stand down
	auto f = makeModuleWithBuiltins();
	scope(exit) freeModule(f.mod);

	// A sort publishes the root's new id; a suspended one leaves it alone, and
	// still reports success so the rest of the schedule runs.
	newRoot = invalidEntity;
	sortSuspended = true;
	scope(exit) sortSuspended = false;
	assert(sortSystem(f.mod, f.root));
	assert(newRoot == invalidEntity);

	sortSuspended = false;
	assert(sortSystem(f.mod, f.root));
	assert(newRoot != invalidEntity);
}
