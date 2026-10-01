/// The machine's register classes, as the backend declares them: which
/// registers the allocator may hand out, which of those survive a call, and
/// which carry arguments.
///
/// New with the D port; the C++ had no register allocator worth the name, only
/// a counter. None of this is the compiler's to decide - a backend says what
/// its machine has, through the `compiler.assembler.*_registers` intrinsics
/// that `opt.computeCompilerNamespace` folds into the lists below, and
/// `mizu.doir` is the one that does so today.
///
/// Three things the shape here exists for, each of which a simpler one gets
/// wrong:
///
///   - *Declarations accumulate.* A class is built from two or three ranges,
///     not one, so each call adds rather than replaces. A machine whose
///     temporaries are split either side of its reserved registers cannot say
///     so otherwise.
///   - *The set is not contiguous.* Neither a single range nor the union of
///     the classes is, because real machines reserve registers in the middle
///     of the numbering. So the allocator walks this list to find its n'th
///     register rather than doing arithmetic on a base.
///   - *It is per compile.* The lists are cleared when a pipeline run starts,
///     the way `canon.clearFallbackScheduleOverride` is: the test runner
///     compiles many modules in one process, and ranges that accumulated
///     across them would hand the second module the first one's machine.
///
/// What is stored is kept normalized: disjoint, non-adjacent, and ascending.
/// A class is a *set* of registers, so two declarations that touch describe
/// one span and are merged into one - which keeps the stored shape from
/// depending on the order a backend wrote its declarations in, lets everything
/// below walk the list without a duplicate check, and makes a declaration
/// folded twice (that pass runs unforced, then forced) cost nothing the second
/// time.
module doir.register_classes;

static import fp.dynarray;
import fp.dynarray : daLength = length;

@nogc nothrow:


/// A span of machine registers, inclusive at both ends - `first == last` is
/// one register, which is how a machine names an odd reserved slot.
struct RegisterRange {
	uint first, last;
}

/// What a range of registers is for. A register may be in more than one:
/// an argument register is usually caller-saved as well, and saying so is the
/// backend's business rather than something to infer.
enum RegisterClass {
	callerSaved,
	calleeSaved,
	argument,
}

/// The classes the allocator draws ordinary values from, in the order it
/// prefers them. Caller-saved first: a value that does not outlive a call
/// should not cost the callee a save.
private static immutable RegisterClass[2] allocatableClasses =
	[RegisterClass.callerSaved, RegisterClass.calleeSaved];

private __gshared RegisterRange*[3] classes;

/// Whether `r` overlaps `[first, last]` or sits immediately beside it.
///
/// Widened to `ulong`, so that a range ending at `uint.max` does not wrap when
/// asked whether the register after it is adjacent.
private bool touches(RegisterRange r, uint first, uint last) {
	return cast(ulong) r.last + 1 >= first && cast(ulong) last + 1 >= r.first;
}

/// Adds a range to a class, merging it with every range it touches.
void declareRegisterRange(RegisterClass cls, uint first, uint last) @trusted {
	if (last < first) return;
	auto list = &classes[cast(size_t) cls];

	// Absorb everything the new range meets, compacting the survivors forward
	// so the merged ones can be dropped off the end in one go.
	size_t kept = 0;
	foreach (i; 0 .. daLength(*list)) {
		immutable r = (*list)[i];
		if (touches(r, first, last)) {
			if (r.first < first) first = r.first;
			if (r.last > last) last = r.last;
		} else (*list)[kept++] = r;
	}
	if (daLength(*list) > kept)
		fp.dynarray.popBackCount(*list, daLength(*list) - kept);

	size_t at = 0;
	while (at < daLength(*list) && (*list)[at].first < first) ++at;
	fp.dynarray.insert(*list, at, RegisterRange(first, last));
}

/// Forgets every declared range. Called when a compile begins.
void clearRegisterClasses() @trusted {
	foreach (i; 0 .. classes.length) {
		fp.dynarray.free(classes[i]);
		classes[i] = null;
	}
}

/// The ranges declared for one class: disjoint, non-adjacent, ascending.
const(RegisterRange)[] registerRanges(RegisterClass cls) @trusted {
	auto a = classes[cast(size_t) cls];
	return a is null ? null : a[0 .. daLength(a)];
}

/// How many registers a class holds.
size_t registerClassSize(RegisterClass cls) {
	size_t out_ = 0;
	foreach (r; registerRanges(cls)) out_ += r.last - r.first + 1;
	return out_;
}

/// The `index`'th register of a class, ascending, or `uint.max` when the class
/// has fewer than that.
///
/// Walked rather than computed: the ranges have gaps between them, so
/// `first + index` is only right for a machine that declared exactly one.
uint registerClassAt(RegisterClass cls, size_t index) {
	foreach (r; registerRanges(cls)) {
		immutable n = r.last - r.first + 1;
		if (index < n) return cast(uint)(r.first + index);
		index -= n;
	}
	return uint.max;
}

/// Whether any range of `cls` holds `reg`.
bool inRegisterClass(RegisterClass cls, uint reg) {
	foreach (r; registerRanges(cls))
		if (reg >= r.first && reg <= r.last) return true;
	return false;
}


// ---------------------------------------------------------------------------
// The allocatable set
// ---------------------------------------------------------------------------

/// Whether an ordinary value may be given `reg`, reached through `cls`.
///
/// Not an argument register: a parameter is pre-coloured onto one of those,
/// and a value that landed on the same register would quietly overwrite it.
/// The two sets usually overlap, since an argument register is normally
/// caller-saved too. What excluding them costs is the argument registers of a
/// function that takes no arguments, which is the trade to take over a
/// collision.
private bool allocatableThrough(RegisterClass cls, uint reg) {
	if (inRegisterClass(RegisterClass.argument, reg)) return false;
	// In both saved classes: offered once, under the first that names it.
	if (cls == RegisterClass.calleeSaved
		&& inRegisterClass(RegisterClass.callerSaved, reg)) return false;
	return true;
}

/// How many registers the allocator may hand out to ordinary values.
size_t allocatableCount() {
	size_t out_ = 0;
	foreach (cls; allocatableClasses)
		foreach (i; 0 .. registerClassSize(cls))
			if (allocatableThrough(cls, registerClassAt(cls, i))) ++out_;
	return out_;
}

/// The `index`'th allocatable register, or `uint.max` past the end.
uint allocatableAt(size_t index) {
	foreach (cls; allocatableClasses)
		foreach (i; 0 .. registerClassSize(cls)) {
			immutable reg = registerClassAt(cls, i);
			if (!allocatableThrough(cls, reg)) continue;
			if (index == 0) return reg;
			--index;
		}
	return uint.max;
}


// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

unittest { // disjoint ranges accumulate rather than replace
	clearRegisterClasses();
	scope(exit) clearRegisterClasses();

	declareRegisterRange(RegisterClass.callerSaved, 1, 3);
	declareRegisterRange(RegisterClass.callerSaved, 10, 11);
	assert(registerRanges(RegisterClass.callerSaved).length == 2);
	assert(registerClassSize(RegisterClass.callerSaved) == 5);
}

unittest { // overlapping ranges merge
	clearRegisterClasses();
	scope(exit) clearRegisterClasses();

	declareRegisterRange(RegisterClass.callerSaved, 1, 4);
	declareRegisterRange(RegisterClass.callerSaved, 3, 6);
	assert(registerRanges(RegisterClass.callerSaved).length == 1);
	assert(registerRanges(RegisterClass.callerSaved)[0] == RegisterRange(1, 6));
}

unittest { // merely adjacent ranges merge too
	clearRegisterClasses();
	scope(exit) clearRegisterClasses();

	// `[1,3]` and `[4,6]` are the same six registers as `[1,6]`.
	declareRegisterRange(RegisterClass.callerSaved, 1, 3);
	declareRegisterRange(RegisterClass.callerSaved, 4, 6);
	assert(registerRanges(RegisterClass.callerSaved).length == 1);
	assert(registerRanges(RegisterClass.callerSaved)[0] == RegisterRange(1, 6));
}

unittest { // one range can swallow several, and a contained one adds nothing
	clearRegisterClasses();
	scope(exit) clearRegisterClasses();

	declareRegisterRange(RegisterClass.callerSaved, 1, 2);
	declareRegisterRange(RegisterClass.callerSaved, 5, 6);
	declareRegisterRange(RegisterClass.callerSaved, 9, 10);
	assert(registerRanges(RegisterClass.callerSaved).length == 3);

	declareRegisterRange(RegisterClass.callerSaved, 2, 9);
	assert(registerRanges(RegisterClass.callerSaved).length == 1);
	assert(registerRanges(RegisterClass.callerSaved)[0] == RegisterRange(1, 10));

	declareRegisterRange(RegisterClass.callerSaved, 4, 5);
	assert(registerRanges(RegisterClass.callerSaved).length == 1);
	assert(registerRanges(RegisterClass.callerSaved)[0] == RegisterRange(1, 10));
}

unittest { // the stored shape does not depend on declaration order
	clearRegisterClasses();
	scope(exit) clearRegisterClasses();

	declareRegisterRange(RegisterClass.callerSaved, 9, 10);
	declareRegisterRange(RegisterClass.callerSaved, 1, 2);
	declareRegisterRange(RegisterClass.callerSaved, 5, 6);

	// Ascending, whatever order they arrived in.
	assert(registerRanges(RegisterClass.callerSaved)[0] == RegisterRange(1, 2));
	assert(registerRanges(RegisterClass.callerSaved)[1] == RegisterRange(5, 6));
	assert(registerRanges(RegisterClass.callerSaved)[2] == RegisterRange(9, 10));
}

unittest { // the same range declared twice is one range
	clearRegisterClasses();
	scope(exit) clearRegisterClasses();

	// What a schedule does: `opt.computeCompilerNamespace` folds unforced and
	// then forced, so every declaration in the source arrives here twice.
	declareRegisterRange(RegisterClass.callerSaved, 1, 20);
	declareRegisterRange(RegisterClass.callerSaved, 1, 20);
	assert(registerRanges(RegisterClass.callerSaved).length == 1);
	assert(registerClassSize(RegisterClass.callerSaved) == 20);
}

unittest { // a range that ends before it begins is not a range
	clearRegisterClasses();
	scope(exit) clearRegisterClasses();

	declareRegisterRange(RegisterClass.callerSaved, 6, 3);
	assert(registerRanges(RegisterClass.callerSaved).length == 0);
}

unittest { // the n'th register is walked, not computed, so gaps are skipped
	clearRegisterClasses();
	scope(exit) clearRegisterClasses();

	// 4..9 reserved, as a real machine reserves the middle of its numbering.
	declareRegisterRange(RegisterClass.callerSaved, 1, 3);
	declareRegisterRange(RegisterClass.callerSaved, 10, 11);

	assert(registerClassAt(RegisterClass.callerSaved, 0) == 1);
	assert(registerClassAt(RegisterClass.callerSaved, 2) == 3);
	// `first + index` would answer 4, which is reserved.
	assert(registerClassAt(RegisterClass.callerSaved, 3) == 10);
	assert(registerClassAt(RegisterClass.callerSaved, 4) == 11);
	assert(registerClassAt(RegisterClass.callerSaved, 5) == uint.max);
}

unittest { // the allocatable set spans both classes and excludes arguments
	clearRegisterClasses();
	scope(exit) clearRegisterClasses();

	declareRegisterRange(RegisterClass.callerSaved, 1, 4);
	declareRegisterRange(RegisterClass.calleeSaved, 20, 21);
	// Argument registers overlap the caller-saved set, as they usually do.
	declareRegisterRange(RegisterClass.argument, 3, 4);

	assert(allocatableAt(0) == 1);
	assert(allocatableAt(1) == 2);
	// 3 and 4 are argument registers, so a value must not land on them.
	assert(allocatableAt(2) == 20);
	assert(allocatableAt(3) == 21);
	assert(allocatableAt(4) == uint.max);
	assert(allocatableCount() == 4);
}

unittest { // a register in both saved classes is offered once
	clearRegisterClasses();
	scope(exit) clearRegisterClasses();

	declareRegisterRange(RegisterClass.callerSaved, 1, 2);
	declareRegisterRange(RegisterClass.calleeSaved, 2, 3);
	assert(allocatableAt(0) == 1);
	assert(allocatableAt(1) == 2);
	assert(allocatableAt(2) == 3);
	assert(allocatableAt(3) == uint.max);
	assert(allocatableCount() == 3);
}

unittest { // clearing is per compile, so one module cannot inherit another's
	clearRegisterClasses();
	declareRegisterRange(RegisterClass.callerSaved, 1, 8);
	assert(registerClassSize(RegisterClass.callerSaved) == 8);

	clearRegisterClasses();
	assert(registerClassSize(RegisterClass.callerSaved) == 0);
	assert(allocatableAt(0) == uint.max);
}
