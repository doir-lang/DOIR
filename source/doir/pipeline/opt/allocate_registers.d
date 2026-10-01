/// `opt.allocateRegisters`: hands every value produced after
/// `begin_register_allocation` the next free register, by synthesizing a
/// `pin_register` call right after it. Ported from opt/allocate_registers.hpp.
module doir.pipeline.opt.allocate_registers;

import ecrs.storage : EntityId, invalidEntity;

static import fp.dynarray;
import fp.dynarray : daLength = length;

import doir.interface_;
import doir.module_;
import doir.string_helpers : InternedString;

@nogc nothrow:


/// Walk state. Thread-local, matching the C++ function-local `static`s (which
/// are likewise reset whenever the walk restarts at a low entity id).
private bool allocating = false;
private size_t nextRegister = 0;

/// Allocates until `endRegisterAllocation` puts back what this returns, for a
/// walk that will never meet a `begin_register_allocation` call of its own.
///
/// `opt.mizu.comptimeEvaluate` lowers two kinds of block that never do: the
/// throwaway program it assembles for one call, which pins every register by
/// hand, and a block an instruction spliced into the module, whose code the
/// program wrote and so needs registers like any other. The flag is a walk's
/// answer to "has allocation started", and neither walk starts where the
/// module's own does. Pair them with `scope(exit)`.
bool beginRegisterAllocation() {
	immutable previous = allocating;
	allocating = true;
	return previous;
}

/// Ditto.
void endRegisterAllocation(bool previous) { allocating = previous; }

bool allocateRegisters(ref Module mod, EntityId subtree) @trusted {
	if (subtree < 5) {
		allocating = false;
		nextRegister = 1;
	}

	if (allocating) {
		immutable pinRegister = resolveCached(mod, "compiler.assembler.pin_register", 1);
		immutable register = resolveCached(mod, "compiler.assembler.register", 1);

		// A parameter is not a value, so it was never allocated: until
		// `opt.liftFunctionBodies` there was no parameter left to allocate for,
		// because the only bodies that reached the machine were inlined ones
		// and inlining substitutes the caller's value for the parameter. A
		// lifted body keeps its parameters, and they are registers - the ones
		// a calling convention would write into. `findFunctionInsideOf` is what
		// tells the two apart: a parameter still inside a function belongs to a
		// declaration nothing jumps to, and allocating for it would renumber
		// every register in every program for nothing.
		immutable liftedParameter = hasComponent!FunctionParameter(mod, subtree)
			&& findFunctionInsideOf(mod, subtree) == invalidEntity;
		if (!(hasComponent!Number(mod, subtree) || hasComponent!DString(mod, subtree)
			|| hasComponent!Call(mod, subtree) || liftedParameter)) return true;
		if (hasComponent!AssignedRegister(mod, subtree)) return true;

		immutable parent = findParent(mod, subtree);
		auto builder = BlockBuilder(parent, &mod);

		// Pin the value to the next register
		immutable type = getComponent!TypeOf(mod, subtree).related[0];
		EntityId[3] inputs = [
			type, subtree, pushNumber(builder, InternedString("_"), register, nextRegister++)
		];
		pushCall(builder, InternedString("_"), register, pinRegister, inputs[]);

		// Move that pin from the end of the block to right after the value is created
		auto related = &getComponent!Block(mod, parent).related;
		size_t at = size_t.max;
		foreach (i; 0 .. daLength(*related))
			if ((*related)[i] == subtree) { at = i + 1; break; }
		if (at != size_t.max)
			foreach (_; 0 .. 2) {
				immutable last = (*related)[daLength(*related) - 1];
				fp.dynarray.popBack(*related);
				fp.dynarray.insert(*related, at, last);
			}

	} else {
		immutable beginRegisterAllocation = resolveCached(mod, "compiler.assembler.begin_register_allocation", 1);
		if (!hasComponent!Call(mod, subtree)) return true;

		immutable func = resolveAlias(mod, getComponent!Call(mod, subtree).related[0]);
		if (func == beginRegisterAllocation) allocating = true;
	}

	return true;
}
