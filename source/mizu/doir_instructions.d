/// The four Mizu instructions DOIR adds so a comptime-evaluated program can
/// reach back into the module that is compiling it. Ported from
/// mizu_doir_instructions.hpp.
///
/// The C++ registered these with Mizu at static-initialisation time
/// (`MIZU_REGISTER_INSTRUCTION`), which let `mizu::from_portable` resolve
/// them by id. The D Mizu has no runtime registration: it builds its
/// instruction table at *compile* time, and `mizu.lookup.Lookup` lets a
/// project extend that table with modules of its own. `doirLookup` below is
/// that extension - Mizu's instructions with these four appended, so Mizu's
/// ids are exactly what they would be without DOIR and ours start at
/// `doirLookup.builtinCount`.
///
/// Hence the module name: this is the Mizu half of DOIR, and it has to be a
/// module Mizu's table template can be handed.
///
/// To serialize or load a program that uses these, pass the lookup to the
/// ordinary Mizu functions - `fromPortable!doirLookup(bytes)`,
/// `toBinary!doirLookup(program)` - instead of letting them default to
/// `Lookup!()`.
module mizu.doir_instructions;

static import fp.dynarray;
import fp.dynarray : daLength = length;

import mizu.lookup : Lookup;
import mizu.opcode;

import ecrs.storage : EntityId;

import doir.interface_;
import doir.module_;

@nogc nothrow:

/// Mizu's instruction table plus the four below.
alias doirLookup = Lookup!(mizu.doir_instructions);


/// Where the comptime evaluator pins the entity currently being evaluated.
/// TODO: Needs to be kept in sync with the location in the comptime
/// evaluation code.
enum Reg currentEntityReg = 2;

/// Where a program's `Module*` lives: one pointer below the stack bottom.
///
/// NOTE: the C++ writes (and reads) the pointer at `env->stack_bottom`
/// itself, which is one past the end of the environment's memory - an
/// out-of-bounds write that happens to work. `doir_set_module` there already
/// decrements `sp` by a pointer's width first, so this uses that slot, which
/// is in bounds and equally self-consistent.
private ulong** modulePointerSlot(RegistersAndStack* env) @trusted {
	return cast(ulong**)(env.stackBottom - (void*).sizeof);
}

private ref Module storedModule(RegistersAndStack* env) @trusted {
	return *cast(Module*)(*modulePointerSlot(env));
}


extern(C) void* doirSetModule(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) @trusted {
	// Set module is expected to be run at the start of the program.
	assert(sp == env.stackBottom);

	sp -= (void*).sizeof;
	assert(sp > env.stackBoundary);
	assert(sp <= env.stackBottom);

	auto mod = cast(Module*) registers[pc.a];
	*modulePointerSlot(env) = cast(ulong*) mod;
	registers[pc.out_] = cast(size_t) mod;

	mixin(mizuNext);
}

extern(C) void* doirAttachComptimeNumberI64(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) @trusted {
	auto mod = &storedModule(env);
	immutable e = cast(EntityId) registers[pc.a];
	auto out_ = &getOrAddComponent!ComptimeNumber(*mod, e);
	out_.value = registers[pc.b];
	registers[pc.out_] = cast(size_t) out_;

	mixin(mizuNext);
}

extern(C) void* doirExecute(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) @trusted {
	auto mod = &storedModule(env);
	immutable e = cast(EntityId) registers[currentEntityReg];
	immutable blk = cast(EntityId) registers[pc.a];
	immutable type = getComponent!TypeOf(*mod, e).related[0];

	immutable copied = deepCopy(*mod, blk);

	stripValue(*mod, e);
	attachSubblock(*mod, e, type);
	inlineInto(*mod, copied, e, 0);

	registers[pc.out_] = e;

	mixin(mizuNext);
}

extern(C) void* doirExecuteIf(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) @trusted {
	auto mod = &storedModule(env);
	immutable e = cast(EntityId) registers[currentEntityReg];
	immutable blk = cast(EntityId) registers[pc.a];

	if (registers[pc.b]) {
		// If the condition is true we inline the block
		immutable type = getComponent!TypeOf(*mod, e).related[0];

		immutable copied = deepCopy(*mod, blk);

		stripValue(*mod, e);
		attachSubblock(*mod, e, type);
		inlineInto(*mod, copied, e, 0);
	} else {
		// Otherwise we erase this call from existence
		immutable parent = findParent(*mod, e);
		auto related = &getComponent!Block(*mod, parent).related;
		for (size_t i = daLength(*related); i-- > 0;)
			if ((*related)[i] == e)
				fp.dynarray.removeAt(*related, i);
	}

	registers[pc.out_] = e;

	mixin(mizuNext);
}
