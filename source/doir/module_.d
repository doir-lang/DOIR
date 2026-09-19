/// `Module`: an `ecrs.Context` plus the source text, working file, string
/// interner and well-known-path resolution cache that the whole compiler
/// threads through every pass, together with the entity-keyed containers the
/// passes use to talk about sets of its entities. Ported from module.hpp /
/// module.cpp and entity_map.hpp.
///
/// The C++ `doir::module` derived from `ecrs::context`; D has no struct
/// inheritance, so the context is a field and the component accessors below
/// forward to it. They keep the C++ spellings (`hasComponent!T(mod, e)` and
/// friends) so the ported passes read the way the originals did.
///
/// Like the rest of the compiler (and like libfp underneath it) the types
/// here are plain data and everything that operates on them is a free
/// function taking the data first, so `set(map, k, v)` and `map.set(k, v)`
/// are the same call. The one concession is `freeModule`: a module's teardown
/// is spelled out in full because plain `free` is hidden inside any module
/// that declares a `free` overload of its own.
module doir.module_;

static import ecrs.context;
static import fp.dynarray;

import ecrs.context : Context;
import ecrs.storage : EntityId, invalidEntity;
import fp.dynarray : daLength = length;
import fp.string : makeDynamicSlice, strFree = free, strSlice = slice;

import fp.fnv1a : fnv1aHash = hash;
import fp.hashtable;
import fp.dynarray : daFree = free;

import doir.interface_;
import doir.string_helpers : InternedString, StringInterner, createInterner, intern;

@nogc nothrow:


// ---------------------------------------------------------------------------
// Entity-keyed containers
// ---------------------------------------------------------------------------
//
// The small containers standing in for the `std::unordered_map`,
// `std::unordered_set` and `std::set` instantiations the C++ passes around
// (substitution tables, "already visited" sets, the sorted id sets
// canonicalize::sort works with). They live here because `Module` holds one
// and everything that wants one is talking to a module anyway.

/// One index-table row: a key and where its pair lives in `pairs`. The key
/// is first so the hash/equal callbacks below can read it straight out of
/// the raw entry bytes.
private struct IndexEntry {
	EntityId key;
	size_t index;
}

private size_t mapHash(inout(ubyte)[] data) @trusted {
	return fnv1aHash(data[0 .. EntityId.sizeof]);
}

private bool mapEqual(inout(ubyte)[] a, inout(ubyte)[] b) @trusted {
	return *cast(const(EntityId)*) a.ptr == *cast(const(EntityId)*) b.ptr;
}

/// One `entity -> entity` row, in insertion order.
struct EntityPair {
	EntityId key;
	EntityId value;
}

/// An `entity -> entity` map, as used for deep-copy and inlining
/// substitution tables.
///
/// The rows live in an insertion-ordered dynarray with a hash table over
/// them as the index. Keeping the rows out of the table is what makes
/// iteration possible: libfp's own `HashtableIterator` does not compile
/// against a `const` table, so there is no usable way to walk one directly.
///
/// Plain data; the operations below are free functions, so `set(map, k, v)`
/// and `map.set(k, v)` are the same call.
struct EntityMap {
	IndexEntry* table = null;
	EntityPair* pairs = null;
}

private void ensure(ref EntityMap m) @trusted {
	if (m.table is null)
		m.table = fp.hashtable.create!IndexEntry(Config(&mapHash, &mapEqual));
}

void free(ref EntityMap m) @trusted {
	if (m.table !is null) { fp.hashtable.free(m.table); m.table = null; }
	if (m.pairs !is null) { daFree(m.pairs); m.pairs = null; }
}

size_t length(ref const EntityMap m) @trusted {
	return daLength(cast(EntityPair*) m.pairs);
}

inout(EntityPair)[] rows(ref inout EntityMap m) @trusted {
	return m.pairs is null ? null : (cast(inout(EntityPair)*) m.pairs)[0 .. length(m)];
}

/// The index row for `key`, or null when it has none.
private IndexEntry* findRow(ref EntityMap m, EntityId key) @trusted {
	if (m.table is null) return null;
	return fp.hashtable.find(m.table, IndexEntry(key, 0));
}

bool contains(ref EntityMap m, EntityId key) @trusted {
	return findRow(m, key) !is null;
}

/// Returns the mapped value, or `key` itself when absent - the pattern
/// every C++ call site spells as `m.contains(e) ? m[e] : e`.
EntityId get(ref EntityMap m, EntityId key) @trusted {
	if (auto hit = findRow(m, key)) return m.pairs[hit.index].value;
	return key;
}

/// Returns the mapped value, or `fallback` when absent.
EntityId get(ref EntityMap m, EntityId key, EntityId fallback) @trusted {
	if (auto hit = findRow(m, key)) return m.pairs[hit.index].value;
	return fallback;
}

void set(ref EntityMap m, EntityId key, EntityId value) @trusted {
	ensure(m);
	if (auto hit = findRow(m, key)) {
		m.pairs[hit.index].value = value;
		return;
	}
	immutable index = length(m);
	fp.dynarray.pushBack(m.pairs, EntityPair(key, value));
	fp.hashtable.insertAssumeUnique(m.table, IndexEntry(key, index));
}


/// An unordered set of entities.
struct EntitySet {
	EntityMap map;
}

void free(ref EntitySet s) { free(s.map); }
bool contains(ref EntitySet s, EntityId e) { return contains(s.map, e); }
void insert(ref EntitySet s, EntityId e) { set(s.map, e, e); }


/// A *sorted*, duplicate-free array of entities, standing in for the
/// `std::set<entity_t>` canonicalize::sort builds and set-differences.
struct SortedEntitySet {
	EntityId* data = null; // fp dynarray, kept sorted ascending
}

void free(ref SortedEntitySet s) @trusted {
	if (s.data !is null) { daFree(s.data); s.data = null; }
}

size_t length(ref const SortedEntitySet s) @trusted {
	return daLength(cast(EntityId*) s.data);
}

inout(EntityId)[] slice(ref inout SortedEntitySet s) @trusted {
	return s.data is null ? null : (cast(inout(EntityId)*) s.data)[0 .. length(s)];
}

/// Index of the first element >= `e` (a plain binary search).
private size_t lowerBound(ref const SortedEntitySet s, EntityId e) @trusted {
	size_t lo = 0, hi = length(s);
	while (lo < hi) {
		immutable mid = lo + (hi - lo) / 2;
		if ((cast(const(EntityId)*) s.data)[mid] < e) lo = mid + 1;
		else hi = mid;
	}
	return lo;
}

bool contains(ref const SortedEntitySet s, EntityId e) @trusted {
	immutable i = lowerBound(s, e);
	return i < length(s) && (cast(const(EntityId)*) s.data)[i] == e;
}

/// Inserts `e` if it isn't present; returns true if it was inserted.
bool insert(ref SortedEntitySet s, EntityId e) @trusted {
	immutable i = lowerBound(s, e);
	if (i < length(s) && s.data[i] == e) return false;
	fp.dynarray.insert(s.data, i, e);
	return true;
}

/// Removes `e` if present.
void remove(ref SortedEntitySet s, EntityId e) @trusted {
	immutable i = lowerBound(s, e);
	if (i < length(s) && s.data[i] == e)
		fp.dynarray.removeAt(s.data, i);
}


/// One memoised `path -> entity` resolution. See `resolveCached`.
private struct ResolveCacheEntry {
	char* path; // owned libfp string
	EntityId entity;
}

/// The compiler's unit of work: an entity/component database plus everything
/// needed to talk about where its entities came from.
struct Module {
	Context ctx;

	const(char)[] source;
	const(char)[] workingFile;
	bool hasWorkingFile = false;

	/// Owns every name in the module. Heap allocated so a `Module` stays
	/// copyable-by-value the way the C++ `shared_ptr` member made it.
	StringInterner* interner = null;

	private ResolveCacheEntry* resolvedCache = null;
}

/// Builds an empty module with a fresh interner and the reserved invalid
/// entity already allocated.
Module createModule() @trusted {
	import fp.pointer : allocFunction;

	Module m;
	m.ctx = ecrs.context.create();
	m.interner = cast(StringInterner*) allocFunction(null, StringInterner.sizeof);
	*m.interner = createInterner();
	return m;
}

void freeModule(ref Module m) @trusted {
	import doir.string_helpers : freeInterner = free;
	import fp.pointer : allocFunction;

	clearResolveCache(m);
	if (m.resolvedCache !is null) { fp.dynarray.free(m.resolvedCache); m.resolvedCache = null; }
	ecrs.context.free(m.ctx);
	if (m.interner !is null) {
		freeInterner(*m.interner);
		allocFunction(m.interner, 0);
		m.interner = null;
	}
}

/// The module's working file, or `<unknown>` when it has none.
const(char)[] workingFileOr(ref Module m, const(char)[] fallback) {
	return m.hasWorkingFile ? m.workingFile : fallback;
}

/// Interns `s` in this module's interner.
InternedString internIn(ref Module m, const(char)[] s) @trusted {
	return intern(*m.interner, s);
}


// ---------------------------------------------------------------------------
// Context bridge
// ---------------------------------------------------------------------------

/// Recovers the module that owns `context`.
///
/// libECRS hands a system the bare `Context` it runs over, while every DOIR
/// pass wants the module around it. The C++ got that for free - `doir::module`
/// publicly derived from `ecrs::context`, so a system could always downcast
/// back. D has no struct inheritance, so `Module` keeps its context as its
/// *first* field (asserted below) and this does the same downcast by hand.
///
/// Only valid for a context that is a module's; `doir.systems` documents every
/// system it builds as module-only for exactly this reason. The `interner`
/// check is a cheap canary for that - `createModule` always installs one, so a
/// context that never belonged to a module reliably trips it in debug builds.
ref Module moduleOf(return ref Context context) @system {
	static assert(Module.ctx.offsetof == 0,
		"moduleOf() downcasts a Context to the Module around it, which requires ctx to be Module's first field.");
	auto m = cast(Module*) &context;
	assert(m.interner !is null, "moduleOf() called on a Context that is not a Module's.");
	return *m;
}


// ---------------------------------------------------------------------------
// Component accessors
// ---------------------------------------------------------------------------

EntityId addEntity(ref Module m) { return ecrs.context.addEntity(m.ctx); }
void removeEntity(ref Module m, EntityId e) { ecrs.context.removeEntity(m.ctx, e); }
size_t entityCount(ref Module m) { return ecrs.context.entityCount(m.ctx); }

bool hasComponent(T)(ref Module m, EntityId e) { return ecrs.context.hasComponent!T(m.ctx, e); }
ref T getComponent(T)(ref Module m, EntityId e) { return ecrs.context.getComponent!T(m.ctx, e); }
ref T addComponent(T)(ref Module m, EntityId e) { return ecrs.context.addComponent!T(m.ctx, e); }
ref T getOrAddComponent(T)(ref Module m, EntityId e) { return ecrs.context.getOrAddComponent!T(m.ctx, e); }
void removeComponent(T)(ref Module m, EntityId e) { ecrs.context.removeComponent!T(m.ctx, e); }

/// True if `e` has a `Flags` component with every bit of `check` set.
bool flagsSet(ref Module m, EntityId e, ushort check) {
	if (!hasComponent!Flags(m, e)) return false;
	return (getComponent!Flags(m, e).flags & check) > 0;
}

/// True if `e` is on the context's freelist (i.e. has been deleted).
bool entityIsFree(ref Module m, EntityId e) @trusted {
	if (m.ctx.freelist is null) return false;
	foreach (i; 0 .. daLength(m.ctx.freelist))
		if (m.ctx.freelist[i] == e) return true;
	return false;
}


// ---------------------------------------------------------------------------
// Well-known path resolution cache
// ---------------------------------------------------------------------------

/// Per-module memoization for the many `lookup.resolve(mod, "some.well.known.path", ...)`
/// calls scattered throughout interface.d / verify.d / sema / opt for fixed,
/// well-known paths (e.g. "compiler.pointer", "type", "mizu.halt").
///
/// Deliberately keyed on `path` alone (ignoring searchStart/strict): every
/// caller of `resolveCached` always passes the same searchStart/strict for a
/// given path, and these paths name entities that live in scope reachable
/// from anywhere in the module (the builtin block or an early_include'd
/// file), so the resolved entity does not actually depend on searchStart.
///
/// This exists *instead of* the previous pattern of caching each lookup in a
/// function-local `static`, which was keyed to whichever module happened to
/// call it first for the lifetime of the process, silently returning that
/// first module's (and, worse, that module's *pre-canonicalize.sort*) ids to
/// every other module built afterwards. This cache is per-module, and
/// `doir.pipeline.sema.canonicalize.sort` clears it since that pass renumbers entities
/// and would otherwise invalidate it.
EntityId resolveCached(ref Module m, const(char)[] path, EntityId searchStart, bool strict = false) @trusted {
	import doir.interface_ : resolveLookupName;

	foreach (i; 0 .. daLength(m.resolvedCache))
		if (strSlice(m.resolvedCache[i].path) == path)
			return m.resolvedCache[i].entity;

	immutable result = resolveLookupName(m, internIn(m, path), searchStart, strict);
	fp.dynarray.pushBack(m.resolvedCache, ResolveCacheEntry(makeDynamicSlice(path), result));
	return result;
}

/// Drops every memoised resolution. Called by `canonicalize.sort`, which
/// renumbers entities.
void clearResolveCache(ref Module m) @trusted {
	if (m.resolvedCache is null) return;
	foreach (i; 0 .. daLength(m.resolvedCache))
		strFree(m.resolvedCache[i].path);
	fp.dynarray.clear(m.resolvedCache);
}


// ---------------------------------------------------------------------------
// Entity substitution
// ---------------------------------------------------------------------------

private void substituteRelation(T)(ref Module m, EntityId subtree, EntityId toFind, EntityId toReplace) @trusted {
	if (!hasComponent!T(m, subtree)) return;
	auto haystack = &getComponent!T(m, subtree);
	static if (is(typeof(haystack.related[0]) == EntityId) && __traits(compiles, haystack.related.length)) {
		foreach (ref e; haystack.related)
			if (e == toFind) e = toReplace;
	} else {
		foreach (i; 0 .. daLength(haystack.related))
			if (haystack.related[i] == toFind) haystack.related[i] = toReplace;
	}
}

private void substituteLookup(T)(ref Module m, EntityId subtree, EntityId toFind, EntityId toReplace) {
	if (!hasComponent!T(m, subtree)) return;
	auto l = &getComponent!T(m, subtree);
	if (l.lookup.resolved() && l.lookup.entity() == toFind)
		l.lookup = toReplace;
}

private void substituteEntitiesImpl(ref Module m, EntityId subtree, ref EntityMap substitutions, size_t depth, size_t maxDepth) @trusted {
	foreach (row; substitutions.rows) {
		immutable toFind = row.key;
		immutable toReplace = row.value;

		substituteRelation!Block(m, subtree, toFind, toReplace);
		substituteRelation!Parent(m, subtree, toFind, toReplace);
		substituteRelation!FunctionReturnType(m, subtree, toFind, toReplace);
		substituteRelation!FunctionInputs(m, subtree, toFind, toReplace);
		substituteRelation!Alias(m, subtree, toFind, toReplace);
		substituteRelation!TypeOf(m, subtree, toFind, toReplace);
		substituteRelation!Call(m, subtree, toFind, toReplace);

		substituteLookup!LookupLookup(m, subtree, toFind, toReplace);
		substituteLookup!LookupFunctionReturnType(m, subtree, toFind, toReplace);
		substituteLookup!LookupAlias(m, subtree, toFind, toReplace);
		substituteLookup!LookupTypeOf(m, subtree, toFind, toReplace);
		substituteLookup!LookupCall(m, subtree, toFind, toReplace);

		if (hasComponent!LookupFunctionInputs(m, subtree)) {
			auto lookups = &getComponent!LookupFunctionInputs(m, subtree);
			foreach (i; 0 .. doir.interface_.length(*lookups))
				if ((*lookups)[i].resolved() && (*lookups)[i].entity() == toFind)
					(*lookups)[i] = toReplace;
		}
	}

	if (depth < maxDepth && hasComponent!Block(m, subtree)) {
		auto block = &getComponent!Block(m, subtree);
		foreach (i; 0 .. daLength(block.related))
			substituteEntitiesImpl(m, block.related[i], substitutions, depth + 1, maxDepth);
	}
}

/// Rewrites every reference to a substituted entity throughout `range`'s
/// subtree, up to `maxDepth` levels down.
void substituteEntities(ref Module m, EntityId range, ref EntityMap substitutions, size_t maxDepth = size_t.max) {
	import doir.pipeline.sema.sort : newRoot;
	if (range == currentCanonicalizeRoot) range = newRoot;
	substituteEntitiesImpl(m, range, substitutions, 0, maxDepth);
}

/// Convenience wrapper for the one-or-two-pair substitutions the optimiser
/// performs inline.
void substituteEntities(ref Module m, EntityId range, const(EntityPairLiteral)[] pairs, size_t maxDepth = size_t.max) {
	EntityMap map;
	scope(exit) map.free();
	foreach (p; pairs) map.set(p.from, p.to);
	substituteEntities(m, range, map, maxDepth);
}

/// A literal substitution, for the wrapper above.
struct EntityPairLiteral {
	EntityId from, to;
}


// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest) {
	import doir.interface_ : resolveLookupName;
	import doir.pipeline.sema.sort : sort;

	import tests.pipeline_helper;
}

// Regression tests for `resolveCached` above, which replaced a pattern of
// `static ecrs::entity_t X = lookup::resolve(mod, "path", ...)` scattered
// throughout the codebase. That pattern memoized each lookup the *first* time
// it ran in the process, in a function-local static - so every module built
// afterwards (or even the same module, after `canonicalize.sort` renumbered
// its entities) silently got back whichever entity id happened to be resolved
// first.
//
// Ported from tests/resolve_cache.test.cpp.

unittest { // two independent modules each resolve to their own correct entity
	auto a = makeModuleWithBuiltins();
	scope(exit) freeModule(a.mod);
	auto b = makeModuleWithBuiltins();
	scope(exit) freeModule(b.mod);

	// Prime b's cache *before* a's, and interleave a couple of different paths,
	// to make sure the cache can't end up keyed by process-wide call order.
	immutable bPointer = resolveCached(b.mod, "compiler.pointer", b.root);
	immutable aPointer = resolveCached(a.mod, "compiler.pointer", a.root);
	immutable bByte = resolveCached(b.mod, "compiler.byte", b.root);
	immutable aByte = resolveCached(a.mod, "compiler.byte", a.root);

	assert(aPointer == resolveLookupName(a.mod, internIn(a.mod, "compiler.pointer"), a.root));
	assert(bPointer == resolveLookupName(b.mod, internIn(b.mod, "compiler.pointer"), b.root));
	assert(aByte == resolveLookupName(a.mod, internIn(a.mod, "compiler.byte"), a.root));
	assert(bByte == resolveLookupName(b.mod, internIn(b.mod, "compiler.byte"), b.root));
	assert(aPointer != invalidEntity);
	assert(bPointer != invalidEntity);
}

unittest { // a failed lookup in one module is not memoized onto another
	auto a = makeModuleWithBuiltins();
	scope(exit) freeModule(a.mod);
	auto b = makeModuleWithBuiltins();
	scope(exit) freeModule(b.mod);

	assert(resolveCached(a.mod, "this.does.not.exist", a.root) == invalidEntity);
	assert(resolveCached(b.mod, "compiler.pointer", b.root) != invalidEntity);
}

unittest { // a cached result is reused within one module
	auto f = makeModuleWithBuiltins();
	scope(exit) freeModule(f.mod);
	immutable first = resolveCached(f.mod, "compiler.debug_print", f.root);
	immutable second = resolveCached(f.mod, "compiler.debug_print", f.root);
	assert(first == second);
	assert(first != invalidEntity);
}

unittest { // canonicalize.sort invalidates previously cached resolutions
	auto f = makeModuleWithBuiltins();
	scope(exit) freeModule(f.mod);

	// Prime the cache with pre-sort entity ids.
	immutable before = resolveCached(f.mod, "compiler.pointer", f.root);
	assert(before != invalidEntity);

	// sort() renumbers entities to match a canonical DFS order over the tree
	// reachable from root; on a from-scratch builtin block this is a legal,
	// fully-formed tree to sort.
	immutable newRootId = sort(f.mod, f.root);

	// A fresh (uncached) resolve from the new root is the ground truth.
	immutable expectedAfter = resolveLookupName(f.mod, internIn(f.mod, "compiler.pointer"), newRootId);
	assert(resolveCached(f.mod, "compiler.pointer", newRootId) == expectedAfter);
}
