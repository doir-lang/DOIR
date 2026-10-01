/// Turns the virtual registers `opt.assignTemporaries` handed out into the
/// machine's own.
///
/// Called from that pass rather than scheduled beside it. The two have to
/// agree exactly on which entities they covered, and they cannot if one is a
/// module pass and the other a visitor: `doir.systems`' ownership filter
/// narrows a visitor to the block being lowered and leaves a module pass
/// looking at everything, so a nested lowering had the sweep renumber the
/// whole module while only part of it was mapped. One pass, one answer.
///
/// The only half of register allocation that knows what machine it is
/// compiling for. The sweep before it answers "how many registers does this
/// program need, and which values share one", which is a fact about the
/// program; this answers "which registers does this machine have, and what are
/// they for", which the backend declared through
/// `compiler.assembler.caller_saved_registers` and its neighbours. A backend
/// with a different register file replaces this pass and reuses the other.
///
/// Two numbering schemes meet here, and the sign is which:
///
///   - a *negative* temporary is a parameter, `-(index + 1)`, and goes to the
///     argument register of that index. The calling convention chose it, not
///     the allocator, which is the whole reason it is numbered apart.
///   - a *positive* temporary is an ordinary value and takes the n'th
///     allocatable register - caller-saved before callee-saved, skipping the
///     argument registers and anything the machine reserved.
///
/// An entity that already carries an `AssignedRegister` is left alone: that is
/// a `compiler.assembler.pin_register`, which names a register the machine
/// fixes rather than one anybody may choose.
///
/// Running out is a diagnostic rather than a spill. Spilling needs somewhere
/// to spill to and a cost model to decide what, and a program that wants more
/// live values than the machine has registers is better told so than silently
/// made slow.
module doir.pipeline.opt.map_temporaries;

import ecrs.storage : EntityId, invalidEntity;

static import fp.dynarray;
import fp.dynarray : daLength = length;

import doir.diagnostics;
import doir.interface_;
import doir.module_;
import doir.register_classes;
import doir.string_helpers : text;

@nogc nothrow:


bool mapTemporary(ref Module mod, EntityId subtree) @trusted {
	if (!hasComponent!Temporary(mod, subtree)) return true;

	immutable id = getComponent!Temporary(mod, subtree).id;
	if (id == 0) return true;

	if (id < 0) {
		immutable index = cast(size_t)(-id - 1);
		immutable reg = registerClassAt(RegisterClass.argument, index);
		if (reg == uint.max) {
			simpleCallError(mod, subtree, text("This is argument ", index + 1,
				", and the machine has only ",
				registerClassSize(RegisterClass.argument),
				" argument registers. Passing more needs a stack convention,",
				" which there is not one of yet."));
			return false;
		}
		getOrAddComponent!AssignedRegister(mod, subtree).reg = reg;
		return true;
	}

	immutable index = cast(size_t)(id - 1);
	immutable reg = allocatableAt(index);
	if (reg == uint.max) {
		// The assignment this points at is the one that went over, because
		// temporaries are handed out in the order values are defined - so it
		// is the first value the machine had no register left for, not an
		// arbitrary one of the many that are now unplaceable.
		simpleCallError(mod, subtree, text("Out of registers: this value wants",
			" the ", index + 1, "th, and the machine has ", allocatableCount(),
			". Nothing spills yet, so this is as many live values as there can be."));
		return false;
	}
	getOrAddComponent!AssignedRegister(mod, subtree).reg = reg;
	return true;
}
