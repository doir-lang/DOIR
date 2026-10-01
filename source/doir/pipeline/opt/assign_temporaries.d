/// `opt.assignTemporaries`: gives every value a virtual register, reusing one
/// as soon as the value in it is dead.
///
/// New with the D port. What it replaces counted: `opt.allocateRegisters`
/// handed out `nextRegister++` and never took one back, so a program used as
/// many registers as it had values and a machine with 257 of them was a
/// ceiling you reached by writing 257 lines. That is also what
/// `compiler.assembler.begin_register_allocation` was for - a marker saying
/// "the standard library is over, start counting here", because otherwise the
/// backend's own declarations spent the whole file before user code began.
/// Reuse removes the need for it, and the test below removes it properly:
/// what decides whether a value gets a register is whether an emitted
/// instruction holds it in one, not where in the file it was written.
///
/// ---------------------------------------------------------------------------
/// Why one sweep rather than a colouring
/// ---------------------------------------------------------------------------
/// The store is SSA - every register is assigned exactly once - and lowering
/// leaves one linear order, the order `byte_emiter` walks. So a value's live
/// range is an *interval*: from where it is defined to where it is last read.
/// The interference graph of a set of intervals is an interval graph, and
/// colouring one greedily left to right, in order of where the intervals
/// start, is optimal - the number of colours it uses is the largest number of
/// intervals overlapping at any point, which is the lower bound for any
/// assignment at all. Building the graph and searching it would be finding by
/// search what the order already says.
///
/// The machine is not consulted here, deliberately: this pass answers "how
/// many registers does the program need, and which values share one", and
/// `opt.mapTemporaries` answers "which registers does this machine have". A
/// backend reuses this one whole.
///
/// ---------------------------------------------------------------------------
/// What an interval cannot see
/// ---------------------------------------------------------------------------
/// A back edge. A value defined inside a loop body and read by the *next*
/// iteration looks dead at the jump, because the jump is behind it in the
/// linear order, and its temporary is handed to something else. There is no
/// control flow graph here to say otherwise - a loop is a label and a jump
/// like any other.
///
/// `std.unsafe.alias_temporaries` is what says it instead: the loop variable
/// and the value an iteration overwrites it with are one temporary, so the
/// range is the union of the two and the reuse cannot happen. That is the same
/// mechanism two arms of an `if` use to agree on where their result lands, and
/// it is why the override exists rather than being a convenience.
module doir.pipeline.opt.assign_temporaries;

import ecrs.storage : EntityId, invalidEntity;

static import fp.dynarray;
import fp.dynarray : daLength = length;

import doir.interface_;
import doir.module_;

import doir.pipeline.canon.sort : loweringThrowawayBlock, newRoot;
import doir.pipeline.opt.lower_functions : needsEmitting;
import doir.pipeline.opt.map_temporaries : mapTemporary;

@nogc nothrow:


/// Not visited, or not a value.
private enum size_t noPosition = size_t.max;


// ---------------------------------------------------------------------------
// Sharing
// ---------------------------------------------------------------------------

/// Union-find over `SharesTemporary`, so that a chain of aliases - `a` with
/// `b`, `b` with `c` - is one set rather than two overlapping pairs.
private EntityId findRoot(EntityId* parent, EntityId e) @trusted {
	while (parent[e] != e) {
		parent[e] = parent[parent[e]]; // halve the path on the way past
		e = parent[e];
	}
	return e;
}

private void unite(EntityId* parent, EntityId a, EntityId b) @trusted {
	immutable ra = findRoot(parent, a);
	immutable rb = findRoot(parent, b);
	if (ra == rb) return;
	// Toward the lower id, so a set's root is its earliest member and the
	// sweep meets the root before anything it stands for.
	if (ra < rb) parent[rb] = ra;
	else parent[ra] = rb;
}


// ---------------------------------------------------------------------------
// The walk
// ---------------------------------------------------------------------------

/// Whether `e` is a function body nothing reaches - a declaration, whose code
/// the machine never runs.
///
/// Its values cost nothing and must not be given registers: between
/// `mizu.doir` and `standard.mizu.doir` there are hundreds of such bodies. A
/// function `opt.claimFunctionLabels` gave labels to is the exception - that
/// one is emitted and jumped to, so its values are as real as any.
///
/// This is what `begin_register_allocation` was reaching for and missing. A
/// marker says "stop counting the standard library", which is a statement
/// about position; this is a statement about whether the machine runs the
/// code, which is the thing that was meant. A declaration written below the
/// marker was counted anyway.
private bool isUnreachedBody(ref Module mod, EntityId e) {
	if (!hasComponent!Block(mod, e)) return false;
	if (hasComponent!FunctionLabels(mod, e)) return false;
	// A function `opt.claimFunctionLabels` has not reached yet but will:
	// nothing consumes it at its call sites, so it is emitted and jumped to,
	// and its values are as real as any. The first round of allocation runs
	// before that pass, so asking it directly is the only way the two agree -
	// guessing left `add_one`'s own constant without a register, and
	// `materializeImmediates` cannot encode a `load_immediate` into one that
	// is not there.
	if (needsEmitting(mod, e)) return false;
	if (hasComponent!FunctionReturnType(mod, e)) return true;
	if (!hasComponent!TypeOf(mod, e)) return false;
	immutable type = resolveTypeModifications(mod,
		resolveAlias(mod, getComponent!TypeOf(mod, e).related[0]));
	return hasComponent!FunctionReturnType(mod, type);
}

/// Numbers every entity in the order the program is emitted in - block list
/// order, descending into each block - which is the order `byte_emiter` walks
/// and therefore the order the machine runs.
private void walkEmissionOrder(ref Module mod, EntityId block,
	ref size_t* position, ref EntityId* order) @trusted
{
	foreach (i; 0 .. daLength(getComponent!Block(mod, block).related)) {
		immutable e = getComponent!Block(mod, block).related[i];
		if (position[e] != noPosition) continue;
		position[e] = daLength(order);
		fp.dynarray.pushBack(order, e);

		// A quoted block is not listed by its parent - `canon.stripFreestandingBlocks`
		// unlinks it so that it is not emitted where it was written - so
		// walking the block lists alone never reaches inside one, and the
		// values in it would get no registers at all. It is emitted where the
		// call that takes it is, because that is where `execute` splices it,
		// so that is where its contents belong in this order: between the
		// arguments of the call and the call itself.
		if (hasComponent!FunctionInputs(mod, e)) {
			auto inputs = &getComponent!FunctionInputs(mod, e);
			foreach (j; 0 .. daLength(inputs.related)) {
				immutable arg = resolveAlias(mod, inputs.related[j]);
				if (arg >= daLength(position) || position[arg] != noPosition) continue;
				if (!hasComponent!Block(mod, arg) || isUnreachedBody(mod, arg)) continue;
				position[arg] = daLength(order);
				fp.dynarray.pushBack(order, arg);
				walkEmissionOrder(mod, arg, position, order);
			}
		}

		if (hasComponent!Block(mod, e) && !isUnreachedBody(mod, e))
			walkEmissionOrder(mod, e, position, order);
	}
}


/// The values an emitted instruction actually holds in a register.
///
/// Asked of the IR rather than guessed from the shape of an entity: an
/// instruction encoder reads its operands through
/// `compiler.assembler.register_for`, and a body names the register it hands
/// back through `yield_register`. Those two calls *are* the demand for
/// registers, so collecting their subjects is the exact answer.
///
/// A heuristic over components would be badly wrong here. `mizu.doir` declares
/// `x0` through `x256` as ordinary numbers at module scope, and a rule that
/// gave every `Number` a register would ask the machine for 257 of them before
/// the program did anything.
private void collectDemand(ref Module mod, const(EntityId)[] order,
	ref bool* needed, ref EntityId* subjectOf) @trusted
{
	immutable registerFor = resolveCached(mod, "compiler.assembler.register_for", 1);
	immutable yieldRegister = resolveCached(mod, "compiler.assembler.yield_register", 1);

	// A leak, and the only one: `load_immediate` and its three siblings have
	// empty bodies, because the bytes they encode include a value nothing in
	// the source names. `opt.mizu.materializeImmediates` writes them, and it
	// reads the destination's `AssignedRegister` straight off the entity
	// rather than asking for it through `register_for` the way an encoder with
	// a body does - so the demand is invisible here unless it is named.
	//
	// Resolved rather than assumed: a module that never included `mizu.doir`
	// answers `invalidEntity` for all four, and a backend of its own would
	// declare its encoders with bodies and need none of this.
	static immutable string[4] immediateLoads = [
		"mizu.load_immediate", "mizu.load_upper_immediate",
		"mizu.load_u64_immediate", "mizu.load_f64_immediate",
	];
	EntityId[4] immediates;
	foreach (i, name; immediateLoads) immediates[i] = resolveCached(mod, name, 1);

	bool loadsAnImmediate(EntityId callee) {
		if (callee == invalidEntity) return false;
		foreach (e; immediates) if (e != invalidEntity && e == callee) return true;
		return false;
	}

	foreach (e; order) {
		if (!hasComponent!Call(mod, e)) continue;
		immutable callee = resolveAlias(mod, getComponent!Call(mod, e).related[0]);

		EntityId subject = invalidEntity;
		if ((callee == registerFor || loadsAnImmediate(callee))
			&& hasComponent!FunctionInputs(mod, e)) {
			auto inputs = &getComponent!FunctionInputs(mod, e);
			// [0] is the type, [1] the value it wants a register for - the
			// same shape for both, which is the one thing that makes the leak
			// above cheap.
			if (daLength(inputs.related) >= 2)
				subject = resolveAlias(mod, inputs.related[1]);
		} else if (callee == yieldRegister) {
			// Resolves to the enclosing block's register, so the block is what
			// needs one - which is how a body hands a value back.
			subject = findParent(mod, e);
		}

		if (subject == invalidEntity || subject >= daLength(needed)) continue;
		needed[subject] = true;
		subjectOf[e] = subject;
	}
}


bool assignTemporaries(ref Module mod, EntityId root = currentCanonicalizeRoot) @trusted {
	// No `loweringThrowawayBlock` guard, unlike most passes that have one.
	// The comptime evaluator lowers two different things under that flag: the
	// throwaway program it assembles for one call, which is hand pinned and
	// which this leaves alone because a pin is a pin; and a block one of its
	// instructions spliced into the module, which is code the program wrote
	// and needs registers like any other. Standing down would starve the
	// second to protect the first.
	//
	// So the sweep runs again, over the whole module, as often as it is asked
	// to. It is idempotent: everything it decided last time it decides again
	// from scratch, which is what keeps a later round from allocating around
	// frozen decisions it cannot see.
	immutable global = root == currentCanonicalizeRoot ? newRoot : root;
	if (!hasComponent!Block(mod, global)) return true;

	immutable count = entityCount(mod);

	size_t* position = null;
	scope(exit) fp.dynarray.free(position);
	fp.dynarray.growToSize(position, count);
	foreach (i; 0 .. count) position[i] = noPosition;

	EntityId* order = null;
	scope(exit) fp.dynarray.free(order);

	walkEmissionOrder(mod, global, position, order);

	bool* needed = null;
	scope(exit) fp.dynarray.free(needed);
	fp.dynarray.growToSize(needed, count);
	foreach (i; 0 .. count) needed[i] = false;

	EntityId* subjectOf = null;
	scope(exit) fp.dynarray.free(subjectOf);
	fp.dynarray.growToSize(subjectOf, count);
	foreach (i; 0 .. count) subjectOf[i] = invalidEntity;

	collectDemand(mod, order[0 .. daLength(order)], needed, subjectOf);

	// --- what shares with what ------------------------------------------
	EntityId* parent = null;
	scope(exit) fp.dynarray.free(parent);
	fp.dynarray.growToSize(parent, count);
	foreach (i; 0 .. count) parent[i] = cast(EntityId) i;

	foreach (i; 0 .. count) {
		immutable e = cast(EntityId) i;
		if (!entityExists(mod, e) || !hasComponent!SharesTemporary(mod, e)) continue;
		immutable other = resolveAlias(mod, getComponent!SharesTemporary(mod, e).related[0]);
		if (other < count) unite(parent, e, other);
	}

	// --- live ranges, per set rather than per entity ----------------------
	// Keyed on the set's root, so that `alias_temporaries` makes one range out
	// of two by construction rather than by a merge afterwards.
	size_t* first = null, last = null;
	scope(exit) { fp.dynarray.free(first); fp.dynarray.free(last); }
	fp.dynarray.growToSize(first, count);
	fp.dynarray.growToSize(last, count);
	foreach (i; 0 .. count) { first[i] = noPosition; last[i] = 0; }

	void note(EntityId e, size_t at) {
		if (e >= count || !needed[e]) return;
		immutable r = findRoot(parent, e);
		if (first[r] == noPosition || at < first[r]) first[r] = at;
		if (at > last[r]) last[r] = at;
	}

	foreach (i; 0 .. daLength(order)) {
		immutable e = order[i];
		note(e, i);                       // where the value is written
		note(subjectOf[e], i);            // where an instruction reads it

		// And anywhere it is merely *named*. Demand is narrow - only a
		// `register_for` says a value is held in a register - but liveness has
		// to be broad, because the first allocation round runs before
		// `opt.inlineFunctions` and the encoder that will ask for the register
		// does not exist yet. At this point `std.add(a, b)` is still a call,
		// and naming `a` is all the evidence there is that `a` is still
		// wanted. Reading it narrowly ended `a`'s range at the
		// `load_immediate` that wrote it, so `a` and `b` shared a register and
		// the addition added one of them to itself.
		if (hasComponent!FunctionInputs(mod, e)) {
			auto inputs = &getComponent!FunctionInputs(mod, e);
			foreach (j; 0 .. daLength(inputs.related))
				note(resolveAlias(mod, inputs.related[j]), i);
		}
		// An alias is a second name for a register, so the register has to
		// outlive the name.
		if (hasComponent!Alias(mod, e))
			note(resolveAlias(mod, getComponent!Alias(mod, e).related[0]), i);
	}

	// --- parameters are not the allocator's to choose ---------------------
	// `-(index + 1)`, so the numbering says which argument slot a parameter
	// wants without naming a register: that is the calling convention's answer
	// and `opt.mapTemporaries` reads it off the machine.
	foreach (i; 0 .. daLength(order)) {
		immutable e = order[i];
		if (!needed[e] || !hasComponent!FunctionParameter(mod, e)) continue;
		immutable index = getComponent!FunctionParameter(mod, e).index;
		getOrAddComponent!Temporary(mod, findRoot(parent, e)).id = -(cast(int) index + 1);
	}

	// --- the sweep --------------------------------------------------------
	// `inUse[t]` is the position after which the temporary `t + 1` is free;
	// `size_t.max` means never.
	size_t* inUse = null;
	scope(exit) fp.dynarray.free(inUse);

	// A temporary once decided is never renumbered, so a later round only
	// fills gaps. That is what makes running this again safe at all: the
	// comptime evaluator lowers blocks with the same schedule while it is
	// part way through assembling a program out of the registers this pass
	// chose, and moving one under it hands the VM something that decodes to
	// nothing. Monotone, so there is nothing to move.
	//
	// The cost is that a value created after the first round - by inlining,
	// or spliced in by an instruction - takes a fresh temporary rather than
	// reusing a dead one. The body of the program, which is swept once and
	// whole, still gets the minimum.
	foreach (i; 0 .. count) {
		immutable e = cast(EntityId) i;
		if (!entityExists(mod, e) || !hasComponent!Temporary(mod, e)) continue;
		immutable id = getComponent!Temporary(mod, e).id;
		if (id <= 0) continue;
		while (daLength(inUse) < cast(size_t) id) fp.dynarray.pushBack(inUse, cast(size_t) 0);
		inUse[id - 1] = size_t.max; // held for good
	}

	foreach (i; 0 .. daLength(order)) {
		immutable e = order[i];
		if (!needed[e]) continue;

		immutable r = findRoot(parent, e);
		// Every member of a set answers to its root's temporary, and the root
		// is the earliest of them, so this is also where a set is first seen.
		if (hasComponent!Temporary(mod, r)) {
			getOrAddComponent!Temporary(mod, e).id = getComponent!Temporary(mod, r).id;
			continue;
		}

		// A pinned register is the machine's choice, not ours - `x0` reads as
		// zero and `ra` holds a return address, and neither is a slot to hand
		// out. A pin is an `AssignedRegister` with no `Temporary` behind it;
		// one *with* a temporary is this pass's own answer from a previous
		// round, which is to be made again rather than treated as fixed.
		if (hasComponent!AssignedRegister(mod, e) && !hasComponent!Temporary(mod, e))
			continue;

		size_t pick = 0;
		while (pick < daLength(inUse) && inUse[pick] >= i) ++pick;
		if (pick == daLength(inUse)) fp.dynarray.pushBack(inUse, cast(size_t) 0);
		inUse[pick] = last[r];

		getOrAddComponent!Temporary(mod, r).id = cast(int)(pick + 1);
		getOrAddComponent!Temporary(mod, e).id = cast(int)(pick + 1);
	}

	// --- and the members of a set that hold no register themselves ---------
	// Demand is narrow by design (`collectDemand`), so a block whose result is
	// computed by a *nested* block asks for nothing: the `register_for` and
	// `yield_register` are one level further in. `alias_temporaries` is
	// routinely aimed at such a block - `std.functions.impl.pass_arguments`
	// unites the body of a `std.copy` with the parameter the argument binds,
	// and the move itself is the encoder block inside that body - so leaving
	// these out of the stamp loses the union exactly where the calling
	// convention needs it.
	//
	// Giving them the set's temporary is the whole of the fix: the register it
	// maps to is what `opt.pinRegisters` hands down through the `return` the
	// body ends in, which is the same walk that carries a pin inward and the
	// only one that knows how far in to go.
	foreach (i; 0 .. daLength(order)) {
		immutable e = order[i];
		if (needed[e] || hasComponent!Temporary(mod, e)) continue;
		immutable r = findRoot(parent, e);
		if (r == e || !hasComponent!Temporary(mod, r)) continue;
		getOrAddComponent!Temporary(mod, e).id = getComponent!Temporary(mod, r).id;
	}

	// Mapped here rather than by a pass of its own: see `mapTemporary`.
	bool ok = true;
	foreach (i; 0 .. daLength(order))
		if (!mapTemporary(mod, order[i])) ok = false;
	return ok;
}
