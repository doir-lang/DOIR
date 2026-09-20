/// The tree walkers every pass is scheduled through, and the fixed-point
/// combinator built on top of them. Ported from systems.hpp.
///
/// These are extensions to `ecrs.system`, not a second scheduling universe
/// beside it. A visitor is a compile-time alias, exactly as
/// `ecrs.system.sequential!fn`'s is, and every walker hands back something
/// libECRS already calls a system: a savable callable in the shape of
/// `ecrs.system.parallel!fn`'s `Bound`, or - through `moduleSystem` - a plain
/// `bool function(ref Context) @nogc nothrow`. So a DOIR pass drops straight
/// into `ecrs.system.sequential(Systems...)` / `parallel(Systems...)`, and
/// `fixedPoint` below accepts anything those accept, DOIR walker or not. The
/// same holds in reverse: libECRS's bound `sequential(a, b)` accepts a
/// `Module`, so a schedule need not reach for `.ctx`.
///
/// The one wrinkle is that libECRS hands a system the bare `Context` while a
/// DOIR visitor wants the `Module` around it; `doir.module_.moduleOf` does
/// that downcast, which is what the C++ got for free from
/// `doir::module : ecrs::context`. Every system built here is therefore
/// module-only: run it on a context that is not a module's and it asserts.
///
/// The C++ built these walkers out of generic lambdas returning
/// `std::function`-ish closures; `-betterC` has neither, but it does have
/// templates, so the visitor travels as an alias rather than as a function
/// pointer plus a `void*` context. That keeps every schedule allocation-free,
/// lets the visitor inline, and drops the untyped `ctx` the earlier port
/// threaded through each walk.
module doir.systems;

static import fp.dynarray;
import fp.dynarray : daLength = length;

import ecrs.context : Context, getStorage;
import ecrs.storage : EntityId, empty, invalidEntity;

/// libECRS's own combinators, so a schedule only has to import this module.
public import ecrs.system : sequential, parallel;

import doir.interface_ : Block, Call, ScheduleClaim, currentCanonicalizeRoot,
	findParent, resolveAlias;
import doir.module_;
import doir.pipeline.sema.sort : canonicalizeSort = sort, newRoot;

@nogc nothrow:


/// What libECRS calls a system: one whole pass over a context. The walkers'
/// `Bound`s and the combinators' results are systems too - `ecrs.system`'s
/// combinators take any of them - so this is the shape a pass takes when
/// something genuinely needs a function pointer, not a toll every pass pays.
alias SystemFunction = bool function(ref Context) @nogc nothrow;

/// Lifts a whole module pass (`bool fn(ref Module)`) into a libECRS system.
///
/// Also the way to get a walker as a function pointer, since the walker
/// templates are eponymous overload sets and so cannot have their address
/// taken directly: `&moduleSystem!(depthFirst!pinRegisters)` is a
/// `SystemFunction` over the canonical root. (A walker only needs this when a
/// function pointer is what is wanted; `depthFirst!fn()` is already a system
/// the combinators accept.)
template moduleSystem(alias fn) {
	bool moduleSystem(ref Context context) @trusted {
		return fn(moduleOf(context));
	}
}

/// Lifts a DOIR visitor (`bool fn(ref Module, EntityId)`) into the
/// `(ref Context, EntityId)` shape `ecrs.system`'s own per-entity walkers
/// expect, so a pass that does not care about tree order can be scheduled by
/// them instead - including in parallel:
/// `ecrs.system.parallel!(visitor!pinRegisters)(mod.ctx, pool)`.
template visitor(alias fn) {
	bool visitor(ref Context context, EntityId e) @trusted {
		return fn(moduleOf(context), e);
	}
}

private EntityId resolveRoot(EntityId subtree) {
	return subtree == currentCanonicalizeRoot ? newRoot : subtree;
}


// ---------------------------------------------------------------------------
// Walkers
// ---------------------------------------------------------------------------
//
// Each walker is a template over the visitor, with three forms:
//
//   walk!fn(mod)            run it now, over the canonical-sort root
//   walk!fn(mod, subtree)   run it now, over `subtree`
//   walk!fn(subtree)        a savable system, for the combinators
//
// (`sorted` takes its `sortWhenFinished` flag after the subtree in both of the
// latter two.)
//
// The savable form is `Bound`, copyable and callable with either a `Module` or
// the `Context` libECRS passes - the same trick `ecrs.system.parallel!fn(pool)`
// uses to bind its pool up front, since capturing state in a delegate would
// need a GC allocation `-betterC` does not have.

private struct Frame {
	EntityId entity;
	size_t childIndex;
}

/// Visits every entity under `subtree`, children before parents.
template depthFirst(alias fn) {
	private bool walk(ref Module mod, EntityId subtree) @trusted {
		Frame* stack = null;
		scope(exit) if (stack !is null) fp.dynarray.free(stack);
		fp.dynarray.pushBack(stack, Frame(resolveRoot(subtree), 0));

		while (daLength(stack) > 0) {
			auto frame = &stack[daLength(stack) - 1];

			if (!hasComponent!Block(mod, frame.entity)) {
				if (ownedByCurrentLowering(mod, frame.entity) && !fn(mod, frame.entity))
					return false;
				fp.dynarray.popBack(stack);
				continue;
			}

			auto block = &getComponent!Block(mod, frame.entity);
			if (frame.childIndex < daLength(block.related)) {
				immutable child = block.related[frame.childIndex];
				++frame.childIndex;
				// May reallocate `stack` (invalidating `frame`), but `frame` is
				// not used again this iteration.
				fp.dynarray.pushBack(stack, Frame(child, 0));
			} else {
				immutable entity = frame.entity;
				if (ownedByCurrentLowering(mod, entity) && !fn(mod, entity)) return false;
				fp.dynarray.popBack(stack);
			}
		}

		return true;
	}

	/// Runs the walk over `subtree` now.
	bool depthFirst(ref Module mod, EntityId subtree) { return walk(mod, subtree); }

	/// Ditto, rooted at whatever `canonicalize.sort` last produced.
	bool depthFirst(ref Module mod) { return walk(mod, currentCanonicalizeRoot); }

	/// The walk as a savable, copyable system.
	struct Bound {
		private EntityId subtree = currentCanonicalizeRoot;

		@nogc nothrow:
		this(EntityId subtree) { this.subtree = subtree; }
		bool opCall(ref Module mod) { return walk(mod, subtree); }
		bool opCall(ref Context context) @trusted { return walk(moduleOf(context), subtree); }
	}

	/// Ditto; `depthFirst!fn()` binds the canonical-sort root.
	Bound depthFirst(EntityId subtree = currentCanonicalizeRoot) { return Bound(subtree); }
}

/// Visits every entity under `subtree`, level by level.
template breadthFirst(alias fn) {
	private bool walk(ref Module mod, EntityId subtree) @trusted {
		EntityId* queue = null;
		scope(exit) if (queue !is null) fp.dynarray.free(queue);
		fp.dynarray.pushBack(queue, resolveRoot(subtree));

		size_t head = 0;
		while (head < daLength(queue)) {
			immutable entity = queue[head++];

			// Skipped, but still descended through: the children below may be
			// owned even when this is not.
			if (ownedByCurrentLowering(mod, entity) && !fn(mod, entity)) return false;

			if (!hasComponent!Block(mod, entity)) continue;
			auto block = &getComponent!Block(mod, entity);
			foreach (i; 0 .. daLength(block.related))
				fp.dynarray.pushBack(queue, getComponent!Block(mod, entity).related[i]);
		}

		return true;
	}

	/// Runs the walk over `subtree` now.
	bool breadthFirst(ref Module mod, EntityId subtree) { return walk(mod, subtree); }

	/// Ditto, rooted at whatever `canonicalize.sort` last produced.
	bool breadthFirst(ref Module mod) { return walk(mod, currentCanonicalizeRoot); }

	/// The walk as a savable, copyable system.
	struct Bound {
		private EntityId subtree = currentCanonicalizeRoot;

		@nogc nothrow:
		this(EntityId subtree) { this.subtree = subtree; }
		bool opCall(ref Module mod) { return walk(mod, subtree); }
		bool opCall(ref Context context) @trusted { return walk(moduleOf(context), subtree); }
	}

	/// Ditto; `breadthFirst!fn()` binds the canonical-sort root.
	Bound breadthFirst(EntityId subtree = currentCanonicalizeRoot) { return Bound(subtree); }
}

/// Visits `subtree`'s entities in id order, exploiting the invariant
/// `canonicalize.sort` establishes: a block's children occupy the contiguous
/// id range ending at the block itself.
///
/// `sortWhenFinished` re-sorts the subtree afterwards, for passes (like
/// `processEarlyInclude`) that add entities as they go.
template sorted(alias fn) {
	private bool walkImpl(ref Module mod, EntityId subtree) @trusted {
		if (!hasComponent!Block(mod, subtree))
			return !ownedByCurrentLowering(mod, subtree) || fn(mod, subtree);

		if (daLength(getComponent!Block(mod, subtree).related) == 0)
			return !ownedByCurrentLowering(mod, subtree) || fn(mod, subtree);

		for (size_t e = getComponent!Block(mod, subtree).related[0]; e <= subtree; ++e) {
			// Re-read the block every iteration: a visitor may have added
			// components and moved it. (The C++ carries a "TODO: Why do we lose
			// the block?" note on exactly this line.)
			auto block = &getComponent!Block(mod, subtree);
			if (e == block.related[0]) {
				// If the first child is a block its full range may not be
				// captured by the loop, so recurse into it.
				if (!walkImpl(mod, cast(EntityId) e)) return false;
			} else if (ownedByCurrentLowering(mod, cast(EntityId) e)
				&& !fn(mod, cast(EntityId) e)) return false;
		}
		return true;
	}

	private bool walk(ref Module mod, EntityId subtree, bool sortWhenFinished) {
		auto root = resolveRoot(subtree);
		immutable out_ = walkImpl(mod, root);
		if (sortWhenFinished)
			canonicalizeSort(mod, root);
		return out_;
	}

	/// Runs the walk over `subtree` now.
	bool sorted(ref Module mod, EntityId subtree, bool sortWhenFinished = false) {
		return walk(mod, subtree, sortWhenFinished);
	}

	/// Ditto, rooted at whatever `canonicalize.sort` last produced.
	bool sorted(ref Module mod) { return walk(mod, currentCanonicalizeRoot, false); }

	/// The walk as a savable, copyable system.
	struct Bound {
		private EntityId subtree = currentCanonicalizeRoot;
		private bool sortWhenFinished = false;

		@nogc nothrow:
		this(EntityId subtree, bool sortWhenFinished) {
			this.subtree = subtree;
			this.sortWhenFinished = sortWhenFinished;
		}
		bool opCall(ref Module mod) { return walk(mod, subtree, sortWhenFinished); }
		bool opCall(ref Context context) @trusted { return walk(moduleOf(context), subtree, sortWhenFinished); }
	}

	/// Ditto; `sorted!fn()` binds the canonical-sort root.
	Bound sorted(EntityId subtree = currentCanonicalizeRoot, bool sortWhenFinished = false) {
		return Bound(subtree, sortWhenFinished);
	}
}


// ---------------------------------------------------------------------------
// Ownership
// ---------------------------------------------------------------------------
//
// A block carrying a `ScheduleClaim` is saying how the code belonging to it is
// lowered. "Belonging" is wider than "inside": a block that
// declares instructions is speaking for every call to those instructions, and
// those calls are written elsewhere - that is the whole point of a block
// declaring them.
//
// So every entity has an owner, and lowering one block means running its
// schedule over the module with everything owned by somebody else skipped.
// That is not the same as running the schedule rooted at each owned entity in
// turn: passes come in an order, and a stateful one
// (`opt.allocateRegisters` hands out consecutive registers across a single
// walk) needs to see all of its entities in one pass before the next pass
// starts. Filtering one global walk preserves that; re-rooting does not.

/// The nearest block around `e` that claimed a schedule, or `invalidEntity`.
private EntityId lexicalOwnerOf(ref Module mod, EntityId e) {
	while (e != invalidEntity) {
		if (hasComponent!ScheduleClaim(mod, e)) return e;
		immutable parent = findParent(mod, e);
		if (parent == e) return invalidEntity; // a block that contains itself: the root
		e = parent;
	}
	return invalidEntity;
}

/// Which scheduled block `e` belongs to, or `invalidEntity` when none does and
/// the module's fallback schedule has it.
///
/// A call belongs to whoever declared what it calls, and only falls back on
/// where it was written when the callee is not somebody's. The callee wins
/// deliberately: a call to `ns.f()` written inside another scheduled block is
/// still a use of `ns`'s declaration, and `ns` is the one that said how its
/// declarations are lowered.
///
/// Free until something claims. Every walk in the compiler asks this about
/// every entity it reaches, so a module with no `compiler.run_schedule` in it
/// must not pay for a parent-chain walk per entity - and with the claim on the
/// block, "has anyone claimed" is one look at whether that component's storage
/// is empty.
EntityId ownerOf(ref Module mod, EntityId e) @trusted {
	if (empty(getStorage!ScheduleClaim(mod.ctx))) return invalidEntity;

	if (hasComponent!Call(mod, e)) {
		immutable callee = resolveAlias(mod, getComponent!Call(mod, e).related[0]);
		if (callee != invalidEntity && callee != e) {
			immutable owner = lexicalOwnerOf(mod, callee);
			if (owner != invalidEntity) return owner;
		}
	}
	return lexicalOwnerOf(mod, e);
}

/// Whether the schedule that is running is a block's own, rather than the
/// module's fallback - the sibling of `fixedPointChanged` below, and ambient
/// for the same reason: a walker's visitor signature is fixed, so a pass that
/// wants to know something about the walk running it has to read it from
/// somewhere rather than be handed it.
///
/// A bool, and not the block's entity id, which is the one thing it must not
/// be: a schedule may `sort`, and a sort renumbers every entity in the module,
/// so an id opened before the run names somebody else by the end of it. Nothing
/// needs the block's identity anyway. `ownedByCurrentLowering` below settles
/// which entities are the running schedule's by comparing *claims* to
/// `currentScheduleSource`, and the block whose schedule it is answers that
/// question about itself; the only thing left for this to say is who gets the
/// code nobody claimed, and that is the fallback schedule's alone.
///
/// Thread-local, which for once is not only a detail: a `LoweringBlock` opened
/// on one thread is not visible to a `parallel` branch running on a worker.
/// That makes the filter vanish rather than go wrong - the dispatched half
/// visits everything - but it means a schedule that both owns and dispatches
/// does not restrict what its dispatched half does.
private bool currentLoweringIsABlocks;

/// Set while an `applyGlobally` schedule node is running: the ownership filter is
/// off and every walk sees the whole module.
///
/// For a phase that allocates a module-wide resource rather than lowering
/// somebody's code. `opt.allocateRegisters` hands out consecutive register
/// numbers and `opt.pinRegisters` records them, and a register is the machine's,
/// not a block's - so partitioning that walk by ownership does not give two
/// blocks their own registers, it gives them the same ones twice, and leaves
/// every value the owner did not declare (a literal the caller wrote, the
/// `begin_register_allocation` call that starts the count) unallocated on the
/// far side of the filter.
private bool currentLoweringIsGlobal = false;

/// Runs the ownership filter off for as long as it is alive, restoring whatever
/// it replaced - so an `applyGlobally` inside a block's schedule widens for that
/// node only.
struct GlobalLowering {
	private bool previous = false;

	@nogc nothrow:
	@disable this(this);
	this(bool unused) {
		previous = currentLoweringIsGlobal;
		currentLoweringIsGlobal = true;
	}
	~this() { currentLoweringIsGlobal = previous; }
}

/// The text of the schedule currently lowering, or null when it is the
/// compiler's own compiled-in one (which has no source to compare against).
///
/// The filter below is about *which schedule*, not which block. Two schedules
/// must not both lower the same entity - that is the whole reason for the
/// ownership filter - but a block whose claim is the very schedule already
/// running is not a second schedule, and carving its code out of that run
/// leaves it lowered by nobody. That is the ordinary case for a backend, which
/// says the same list twice: `compiler.run_schedule` so the block owns the
/// calls to its declarations, and `compiler.override_fallback_schedule` so the
/// module is lowered that way too.
private const(char)[] currentScheduleSource;

/// How many lowering schedules are running, nested.
///
/// Zero outside all of them, and the filter is then off entirely. The filter
/// partitions *lowering* - it is there so two schedules do not both lower the
/// same entity - and canonicalize, sema and comptime evaluation are not
/// lowering anybody's code: they have to see the whole module.
///
/// This used to be read off the lowering block, which cannot tell "no schedule
/// is running" from "the module's own schedule is running", since neither is a
/// block. That was harmless only while no claim existed before
/// lowering began, and a claim comes into being earlier than that: the schedule
/// holding `opt.runSchedule` is itself run once per block `opt.comptimeEvaluate`
/// lowers, so the first comptime call in the compile creates the claim, and
/// every sema walk after it - `comptimeEvaluateVisitor` included - then skipped
/// everything the claim owned.
private size_t loweringDepth;

/// Ditto.
const(char)[] loweringSchedule() { return currentScheduleSource; }

/// Whether `source` is the schedule that is running - interned, so this is
/// identity, not a comparison of the text.
bool isCurrentSchedule(const(char)[] source) @trusted {
	return source.ptr !is null && source.ptr is currentScheduleSource.ptr
		&& source.length == currentScheduleSource.length;
}

/// Names the schedule running for as long as it is alive, restoring whatever
/// it replaced.
struct LoweringSchedule {
	private const(char)[] previous;

	@nogc nothrow:
	@disable this(this);
	this(const(char)[] source) {
		previous = currentScheduleSource;
		currentScheduleSource = source;
		++loweringDepth;
	}
	~this() {
		currentScheduleSource = previous;
		--loweringDepth;
	}
}

/// Opens a lowering block for as long as it is alive. Nested ones restore the
/// one they replaced, so a schedule run from inside a block's schedule narrows
/// rather than clears.
///
/// Takes the block it is opened for, and keeps only whether there was one; see
/// `currentLoweringIsABlocks` on why the id must not outlive the call.
struct LoweringBlock {
	private bool previous;

	@nogc nothrow:
	@disable this(this);
	this(EntityId blockEntity) {
		previous = currentLoweringIsABlocks;
		currentLoweringIsABlocks = blockEntity != invalidEntity;
	}
	~this() { currentLoweringIsABlocks = previous; }
}

/// Whether the walk should hand `e` to its visitor: one rule, both ways round.
///
/// A block's schedule sees what that block owns. The module's fallback schedule
/// is nobody's block, so it sees what nobody owns - which is the same rule, not
/// an exception to it. Claiming a schedule is therefore taking the code over
/// rather than asking for something extra on top: whatever a block claimed, the
/// fallback schedule leaves alone, and the two never lower the same entity twice.
///
/// Nothing is filtered before the first claim is made, because with no
/// scheduled blocks everything is unowned - so every walk ahead of
/// `opt.runSchedule` (all of canonicalize and sema, and the passes standing in
/// front of it in the lowering schedule) sees the whole module, as it always
/// has.
///
/// Note what this does *not* say: a walk still descends through an entity it
/// skips. A scheduled block can sit inside a block nobody claimed, and the
/// children on the far side of it are reachable no other way.
///
/// Public because one pass has to ask it about an entity no walk handed it:
/// `opt.inlineFunctions` copies a body in from wherever that body was declared,
/// which is the one thing a pass does that the walk reaching it does not bound.
bool ownedByCurrentLowering(ref Module mod, EntityId e) {
	if (loweringDepth == 0) return true;
	if (currentLoweringIsGlobal) return true;

	immutable owner = ownerOf(mod, e);

	// Code nobody claimed is the fallback schedule's share, and only its share.
	if (owner == invalidEntity) return !currentLoweringIsABlocks;

	// Owned by somebody who asked for exactly the schedule that is running -
	// the block whose schedule this is among them, since its own claim is that
	// schedule. Nobody else is going to lower any of them: a claim stands down
	// when its schedule is already the one running, see `opt.run_schedule`, so
	// skipping them here would leave them untouched rather than lower them twice.
	return hasComponent!ScheduleClaim(mod, owner)
		&& isCurrentSchedule(getComponent!ScheduleClaim(mod, owner).source.view);
}


// ---------------------------------------------------------------------------
// Fixed point
// ---------------------------------------------------------------------------

/// Set by any pass that changed something, to ask `fixedPoint` for another
/// round. Thread-local, matching the C++ `bool&` accessor's storage.
private bool* fixedPointChangedStack = null;

/// Where the flag goes for a pass run outside any `fixedPoint` - which is how
/// the per-pass tests call them, and how a schedule may run a pass that only
/// asks for another round when it is nested in one. There is no round to ask
/// for, so the write lands here and is dropped rather than dereferencing the
/// empty stack.
private bool fixedPointChangedDetached = false;

ref bool fixedPointChanged() {
	if (fp.dynarray.empty(fixedPointChangedStack))
		return fixedPointChangedDetached;
	return *fp.dynarray.back(fixedPointChangedStack);
}

/// Runs `system` until it stops reporting changes.
///
/// `System` is whatever libECRS calls a system - a `SystemFunction`, one of
/// the walkers' `Bound`s, or another combinator's result - so this nests
/// inside (and around) `ecrs.system.sequential` / `parallel` freely.
bool fixedPoint(System)(ref Context context, System system) {
	fp.dynarray.pushBack(fixedPointChangedStack, fixedPointChangedDetached);
	scope(exit) 
		if(fp.dynarray.length(fixedPointChangedStack) > 1)
			fp.dynarray.popBack(fixedPointChangedStack);
		else {
			fixedPointChangedDetached = fixedPointChangedStack[0];
			fp.dynarray.free(fixedPointChangedStack);
		}
	do {
		fixedPointChanged() = false;
		if (!system(context)) return false;
	} while (fixedPointChanged());
	return true;
}

/// Ditto, for a module directly.
bool fixedPoint(System)(ref Module mod, System system) {
	return fixedPoint(mod.ctx, system);
}

/// `fixedPoint` as a savable, copyable system, so a fixed-pointed pass can be
/// handed to a combinator like any other.
struct FixedPoint(System) {
	private System system;

	@nogc nothrow:
	this(System system) { this.system = system; }
	bool opCall(ref Context context) { return .fixedPoint(context, system); }
	bool opCall(ref Module mod) { return .fixedPoint(mod.ctx, system); }
}

/// Ditto.
FixedPoint!System fixedPoint(System)(System system) {
	return FixedPoint!System(system);
}


// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest) {
	static import ecrs.system;
	import bc.threadpool : ThreadPool;

	/// Where the test visitors record what they were handed: a visitor is an
	/// alias to a plain function, so it carries no state of its own.
	private EntityId[16] visitLog;
	private size_t visitCount;

	private void resetLog() { visitCount = 0; }

	private bool logIs(scope const EntityId[] expected) {
		if (visitCount != expected.length) return false;
		foreach (i, e; expected)
			if (visitLog[i] != e) return false;
		return true;
	}

	private bool record(ref Module mod, EntityId e) {
		if (visitCount < visitLog.length) visitLog[visitCount++] = e;
		return true;
	}

	/// Records, then fails once it has seen three entities.
	private bool recordThenFail(ref Module mod, EntityId e) {
		cast(void) record(mod, e);
		return visitCount < 3;
	}

	/// A whole pass that reports a change until it has run four times.
	private bool bumpUntilFour(ref Module mod) {
		if (visitCount >= 4) return true;
		++visitCount;
		fixedPointChanged() = true;
		return true;
	}

	/// root
	///  +- inner
	///  |   +- leafA
	///  |   +- leafB
	///  +- leafC
	///
	/// Ids are allocated children-first, so the tree also satisfies the
	/// contiguous-id invariant `sorted` relies on.
	private struct Tree {
		Module mod;
		EntityId leafA, leafB, inner, leafC, root;
	}

	private void link(ref Module mod, EntityId block, EntityId child) @trusted {
		auto related = &getComponent!Block(mod, block).related;
		fp.dynarray.pushBack(*related, child);
	}

	private Tree makeTree() {
		Tree t;
		t.mod = createModule();
		t.leafA = addEntity(t.mod);
		t.leafB = addEntity(t.mod);
		t.inner = addEntity(t.mod);
		addComponent!Block(t.mod, t.inner);
		t.leafC = addEntity(t.mod);
		t.root = addEntity(t.mod);
		addComponent!Block(t.mod, t.root);

		link(t.mod, t.inner, t.leafA);
		link(t.mod, t.inner, t.leafB);
		link(t.mod, t.root, t.inner);
		link(t.mod, t.root, t.leafC);

		resetLog();
		return t;
	}
}

unittest { // each walker visits the whole subtree, in its own order
	auto t = makeTree();
	scope(exit) freeModule(t.mod);

	EntityId[5] postOrder = [t.leafA, t.leafB, t.inner, t.leafC, t.root];
	EntityId[5] levelOrder = [t.root, t.inner, t.leafC, t.leafA, t.leafB];

	assert(depthFirst!record(t.mod, t.root));
	assert(logIs(postOrder[]));

	resetLog();
	assert(breadthFirst!record(t.mod, t.root));
	assert(logIs(levelOrder[]));

	// `sorted` reaches the same entities as the depth-first walk by walking the
	// id range instead of the tree.
	resetLog();
	assert(sorted!record(t.mod, t.root));
	assert(logIs(postOrder[]));
}

unittest { // the bound form is a system: libECRS's own combinator can run it
	auto t = makeTree();
	scope(exit) freeModule(t.mod);

	// `ecrs.system.sequential(Systems...)` only knows how to call something
	// with the context, which is exactly what `Bound` accepts.
	assert(ecrs.system.sequential(t.mod.ctx,
		depthFirst!record(t.root),
		breadthFirst!record(t.root)));
	assert(visitCount == 10);

	// ... `parallel` takes the walkers as readily, mixed with anything else
	// that is a system ...
	ThreadPool* pool = null;
	static assert(__traits(compiles, ecrs.system.parallel(t.mod.ctx, pool,
		depthFirst!record(t.root),
		&moduleSystem!(depthFirst!record))));
	static assert(__traits(compiles, ecrs.system.parallel!(visitor!record)(t.mod.ctx, pool)));

	// ... and `moduleSystem` still turns one into a plain function pointer,
	// for where a `SystemFunction` is what is actually wanted.
	resetLog();
	SystemFunction asFunction = &moduleSystem!(depthFirst!record);

	// The function-pointer form walks whatever `canonicalize.sort` last
	// produced, so point that at the tree first.
	immutable backup = newRoot;
	newRoot = t.root;
	scope(exit) newRoot = backup;
	assert(asFunction(t.mod.ctx));
	assert(visitCount == 5);
}

unittest { // `visitor` lets libECRS's per-entity walkers drive a DOIR pass
	auto t = makeTree();
	scope(exit) freeModule(t.mod);

	// Every *live* entity, tree or not - including the reserved invalid one.
	assert(ecrs.system.sequential!(visitor!record)(t.mod.ctx));
	EntityId[6] all = [invalidEntity, t.leafA, t.leafB, t.inner, t.leafC, t.root];
	assert(logIs(all[]));
}

unittest { // sequential stops at the first failing system
	auto t = makeTree();
	scope(exit) freeModule(t.mod);

	// The second walk never runs, so the log stops at the three entities the
	// first one got through.
	assert(!ecrs.system.sequential(t.mod.ctx,
		depthFirst!recordThenFail(t.root),
		depthFirst!record(t.root)));
	assert(visitCount == 3);

	// Ditto through the bound form, which takes the module directly.
	resetLog();
	assert(!ecrs.system.sequential(
		depthFirst!recordThenFail(t.root),
		depthFirst!record(t.root),
	)(t.mod));
	assert(visitCount == 3);
}

unittest { // fixedPoint re-runs a system while it reports changes, and is one
	auto t = makeTree();
	scope(exit) freeModule(t.mod);

	assert(fixedPoint(t.mod, &moduleSystem!bumpUntilFour));
	assert(visitCount == 4);

	// The savable form nests inside another combinator like any other system.
	resetLog();
	assert(ecrs.system.sequential(
		fixedPoint(&moduleSystem!bumpUntilFour),
		depthFirst!record(t.root),
	)(t.mod));
	assert(visitCount == 4 + 5);
}

unittest {
	// Every walker offers the same four spellings: run now over a named
	// subtree, run now over whatever `canonicalize.sort` last produced, and
	// each of those as a `Bound` system. The `Bound.opCall(ref Module)` half
	// is what a schedule built out of `doir.pipeline`'s combinators calls.
	import doir.pipeline.sema.sort : sort;

	auto t = makeTree();
	scope(exit) freeModule(t.mod);

	EntityId[5] postOrder = [t.leafA, t.leafB, t.inner, t.leafC, t.root];
	EntityId[5] levelOrder = [t.root, t.inner, t.leafC, t.leafA, t.leafB];

	assert(depthFirst!record(t.root)(t.mod));
	assert(logIs(postOrder[]));

	resetLog();
	assert(breadthFirst!record(t.root)(t.mod));
	assert(logIs(levelOrder[]));

	resetLog();
	assert(sorted!record(t.root, false)(t.mod));
	assert(logIs(postOrder[]));

	// Rooted at the canonical sort instead. The ids change under it, so this
	// only checks how many entities the walk reached.
	immutable newRootId = sort(t.mod, t.root);
	assert(newRootId != invalidEntity);

	resetLog();
	assert(depthFirst!record(t.mod));
	assert(visitCount == 5);

	resetLog();
	assert(breadthFirst!record(t.mod));
	assert(visitCount == 5);

	resetLog();
	assert(sorted!record(t.mod));
	assert(visitCount == 5);

	resetLog();
	assert(depthFirst!record()(t.mod));
	assert(visitCount == 5);

	resetLog();
	assert(breadthFirst!record()(t.mod));
	assert(visitCount == 5);

	resetLog();
	assert(sorted!record()(t.mod));
	assert(visitCount == 5);
}

unittest { // `FixedPoint` runs over a module as well as over a context
	auto t = makeTree();
	scope(exit) freeModule(t.mod);

	auto system = fixedPoint(&moduleSystem!bumpUntilFour);
	assert(system(t.mod));
	assert(visitCount == 4);

	resetLog();
	assert(system(t.mod.ctx));
	assert(visitCount == 4);
}
