/// Building and running the Mizu program a comptime evaluation is.
///
/// New with the D port, replacing the way `opt.mizu.comptimeEvaluate` used to
/// get from a call to a runnable program. What it replaced went the long way
/// round: synthesize a throwaway *DOIR block* full of `load_immediate` and
/// `pin_register` calls, run the whole backend lowering schedule over it, emit
/// bytes, decode the bytes back into a program, and run that. Evaluating
/// `add(1, 2)` ran the compiler on itself.
///
/// Everything that made comptime evaluation fragile followed from that path
/// rather than from the idea:
///
///   - it hand-pinned registers by counting, with a magic start value tuned to
///     what the register allocator happened to do, so changing the allocator
///     changed what folded;
///   - it needed `sortSuspended` and a saved `newRoot`, because lowering a
///     block means sorting and the sort renumbers the module the outer walk is
///     holding ids into;
///   - it needed an `evaluating` re-entrancy guard, because the schedule it
///     ran contains the evaluator;
///   - and the inliner had to be told to stand down for calls it might
///     otherwise consume, which it did by *predicting* what would fold.
///
/// An `Opcode` is a function pointer and three register numbers. Nothing about
/// that needs a compiler pass. So this builds the array directly: the
/// evaluator owns registers 0 upwards, assigns them as it writes, and hands
/// the result to the VM. No lowering, no emission, no decode, and no register
/// the rest of the compiler can see.
///
/// The idea the old path was reaching for is kept: a comptime operation *is* a
/// Mizu instruction, defined once in `doir.mizu.instructions` and executed
/// against the live store. Only the route from a DOIR call to that instruction
/// changes.
module doir.comptime.program;

import core.stdc.string : memcpy;

import ecrs.storage : EntityId, invalidEntity;

static import fp.dynarray;
import fp.dynarray : daLength = length;

import mizu.lookup : Id;
import mizu.opcode : Instruction, Opcode, Reg, RegistersAndStack,
	setupEnvironment, startFromEnvironment;

import doir.interface_;
import doir.mizu.instructions : currentEntityReg, doirLookup;
import doir.module_;

import mizu.instructions.core : coreHalt = halt, coreLoadImmediate = loadImmediate,
	coreLoadUpperImmediate = loadUpperImmediate;

@nogc nothrow:


/// The register the `Module*` is loaded into before `set_module` stores it.
/// One, because `currentEntityReg` is two and the entity has to survive the
/// whole program while this does not.
private enum Reg moduleReg = 1;

/// The two registers a constant operand is loaded into.
///
/// Scratch rather than one each, because a program is a whole *region* of
/// calls rather than one: a constant is dead as soon as the instruction after
/// it has read it, while a result has to survive until whatever reads it, and
/// only the second kind is worth a register of its own. Two, because an
/// `Opcode` has two operand slots.
private enum Reg firstOperandReg = 3;

/// Where results start: past the module register, the current entity and the
/// two operand scratches.
private enum Reg firstResultReg = 5;

/// Mizu's register file is the first 256 words of the environment's memory,
/// the rest being stack, so this is how many results one program can hold
/// live at once. `doir.pipeline.opt.mizu.comptime_evaluate` sizes a region
/// against it.
enum size_t maximumResults = 256 - firstResultReg;


// ---------------------------------------------------------------------------
// Which instruction a callee is
// ---------------------------------------------------------------------------

/// The Mizu instruction `callee` encodes, or `null` if it encodes none.
///
/// Read out of the callee's own body rather than mapped from its name.
/// `mizu.doir` is generated, and each binding's body opens by emitting eight
/// bytes that are the instruction's id - that string is the one place the id
/// is written down, so reading it is reading the source of truth instead of
/// duplicating `tools/mizu_gen`'s name mangling and hoping the two agree.
Instruction instructionOf(ref Module mod, EntityId callee) @trusted {
	if (!hasComponent!Block(mod, callee)) return null;

	auto related = &getComponent!Block(mod, callee).related;
	foreach (i; 0 .. daLength(*related)) {
		immutable e = (*related)[i];
		if (!hasComponent!DString(mod, e)) continue;
		auto view = getComponent!DString(mod, e).value.view;
		// Eight bytes exactly: an instruction id fills a pointer-sized slot,
		// and every other string in a body is an operand or padding.
		if (view.length != 8) continue;

		ulong id = 0;
		foreach (j; 0 .. 8) id |= cast(ulong)(cast(ubyte) view[j]) << (8 * j);
		if (!doirLookup.validId(cast(Id) id)) return null;
		return doirLookup.lookupPointer(cast(Id) id);
	}
	return null;
}


// ---------------------------------------------------------------------------
// Building
// ---------------------------------------------------------------------------

/// A program under construction. Owns its opcodes; free with `free`.
struct ComptimeProgram {
	Opcode* opcodes;
	/// The next register nothing has claimed.
	Reg nextRegister = firstResultReg;
}

void free(ref ComptimeProgram p) @trusted {
	fp.dynarray.free(p.opcodes);
	p.opcodes = null;
}

private void emit(ref ComptimeProgram p, Instruction op, Reg out_, Reg a, Reg b) @trusted {
	Opcode o;
	o.op = op;
	o.out_ = out_;
	o.a = a;
	o.b = b;
	fp.dynarray.pushBack(p.opcodes, o);
}

private void emitImmediate(ref ComptimeProgram p, Instruction op, Reg out_, uint value) @trusted {
	Opcode o;
	o.op = op;
	o.out_ = out_;
	o.setImmediate(value);
	fp.dynarray.pushBack(p.opcodes, o);
}

/// Loads a whole 64 bit value into `reg`, in the two halves Mizu's 32 bit
/// immediates allow. The upper half is skipped when it is zero, which is every
/// entity id and most numbers; a pointer needs both.
void loadValue(ref ComptimeProgram p, Reg reg, ulong value) {
	emitImmediate(p, &coreLoadImmediate, reg, cast(uint) value);
	if (value >> 32)
		emitImmediate(p, &coreLoadUpperImmediate, reg, cast(uint)(value >> 32));
}

/// Claims the next free register and loads `value` into it.
Reg pushValue(ref ComptimeProgram p, ulong value) {
	immutable reg = p.nextRegister++;
	loadValue(p, reg, value);
	return reg;
}

/// Opens the program: tells the instructions which module they are editing.
///
/// `set_module` asserts it runs with the stack pointer still at the bottom, so
/// this has to come first and exactly once.
void begin(ref ComptimeProgram p, ref Module mod, Instruction setModule) @trusted {
	loadValue(p, moduleReg, cast(ulong) cast(size_t) &mod);
	emit(p, setModule, 0, moduleReg, 0);
}

/// Names the entity an instruction is acting for, in the register
/// `doir.mizu.instructions` reads it from.
void setCurrentEntity(ref ComptimeProgram p, EntityId e) {
	loadValue(p, currentEntityReg, e);
}

/// Appends one call: its arguments into fresh registers, then the instruction.
/// Returns the register holding the result.
Reg call(ref ComptimeProgram p, Instruction op, const(ulong)[] arguments) {
	Reg[2] args = [0, 0];
	foreach (i, a; arguments) {
		if (i >= args.length) break;
		args[i] = pushValue(p, a);
	}
	immutable out_ = p.nextRegister++;
	emit(p, op, out_, args[0], args[1]);
	return out_;
}

/// Appends one call whose operands are already in registers - a result from
/// an earlier call rather than a value known here.
Reg callWith(ref ComptimeProgram p, Instruction op, Reg a, Reg b) {
	immutable out_ = p.nextRegister++;
	emit(p, op, out_, a, b);
	return out_;
}

/// Loads a constant into operand slot `index`'s scratch register and hands
/// that register back.
Reg loadOperand(ref ComptimeProgram p, size_t index, ulong value)
in (index < 2) {
	immutable reg = cast(Reg)(firstOperandReg + index);
	loadValue(p, reg, value);
	return reg;
}

/// Appends one call whose result nothing reads - the store write that ends
/// each call in a region. It goes to an operand scratch, which is dead by
/// then, rather than claiming a register nothing will ever look at.
void callDiscarding(ref ComptimeProgram p, Instruction op, Reg a, Reg b) {
	emit(p, op, firstOperandReg, a, b);
}

/// The register `setCurrentEntity` writes, for a call that takes the entity
/// being evaluated as an operand.
Reg currentEntityRegister() { return currentEntityReg; }

/// Closes the program. A Mizu program runs until something returns null, so
/// without this the VM walks off the end of the array.
void end(ref ComptimeProgram p) {
	emit(p, &coreHalt, 0, 0, 0);
}


// ---------------------------------------------------------------------------
// Running
// ---------------------------------------------------------------------------

/// Runs the program. False when there is nothing to run, which is not a
/// failure - a module with no backend loaded resolves no instructions.
bool run(ref ComptimeProgram p) @trusted {
	immutable count = daLength(p.opcodes);
	if (count == 0) return false;

	RegistersAndStack environment;
	setupEnvironment(environment, p.opcodes, p.opcodes + count);
	startFromEnvironment(p.opcodes, environment);
	return true;
}


// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest) {
	import doir.diagnostics : diagnostics;
	import doir.pipeline.canon.sort : newRoot;
	import tests.pipeline_helper : find, withMizu;
}

unittest { // a binding's body is where its instruction id is written down
	auto f = withMizu("comptime_program.doir");
	scope(exit) freeModule(f.mod);

	assert(instructionOf(f.mod, find(f.mod, newRoot, "mizu.doir.set_module")) !is null);
	assert(instructionOf(f.mod, find(f.mod, newRoot, "mizu.doir.intern_name")) !is null);

	// A declaration with no body encodes nothing, and must not be guessed at.
	assert(instructionOf(f.mod, find(f.mod, newRoot, "mizu.u64")) is null);
	diagnostics().clear();
}

unittest { // a program built directly edits the live store
	// The whole architecture in one test: the instruction is found by reading
	// the generated binding, the program is an `Opcode[]` this module wrote
	// rather than DOIR that was lowered, and running it reaches into the
	// `Module` the compiler is holding. No schedule, no emission, no decode.
	auto f = withMizu("comptime_program.doir");
	scope(exit) freeModule(f.mod);

	immutable setModule = instructionOf(f.mod, find(f.mod, newRoot, "mizu.doir.set_module"));
	immutable attach = instructionOf(f.mod,
		find(f.mod, newRoot, "mizu.doir.attach_comptime_number_i64"));
	assert(setModule !is null && attach !is null);

	immutable target = addEntity(f.mod);
	assert(!hasComponent!ComptimeNumber(f.mod, target));

	ComptimeProgram p;
	scope(exit) free(p);
	begin(p, f.mod, setModule);
	setCurrentEntity(p, target);
	ulong[2] arguments = [target, 1234];
	call(p, attach, arguments[]);
	end(p);
	assert(run(p));

	assert(hasComponent!ComptimeNumber(f.mod, target));
	assert(getComponent!ComptimeNumber(f.mod, target).value == 1234);
	diagnostics().clear();
}

unittest { // a value wider than an immediate survives, in both halves
	// The `Module*` goes through this path, and a single 32 bit load silently
	// truncated it - which is how a pointer argument used to reach an
	// instruction as a wild address.
	auto f = withMizu("comptime_program.doir");
	scope(exit) freeModule(f.mod);

	immutable setModule = instructionOf(f.mod, find(f.mod, newRoot, "mizu.doir.set_module"));
	immutable attach = instructionOf(f.mod,
		find(f.mod, newRoot, "mizu.doir.attach_comptime_number_i64"));

	immutable target = addEntity(f.mod);
	enum ulong wide = 0x1234_5678_9ABCUL;

	ComptimeProgram p;
	scope(exit) free(p);
	begin(p, f.mod, setModule);
	setCurrentEntity(p, target);
	ulong[2] arguments = [target, wide];
	call(p, attach, arguments[]);
	end(p);
	assert(run(p));

	assert(getComponent!ComptimeNumber(f.mod, target).value == wide);
	diagnostics().clear();
}

unittest { // several calls in one program, which is what a region will be
	// The old path built, lowered, emitted, decoded and ran one program per
	// call. Appending is all a region needs.
	auto f = withMizu("comptime_program.doir");
	scope(exit) freeModule(f.mod);

	immutable setModule = instructionOf(f.mod, find(f.mod, newRoot, "mizu.doir.set_module"));
	immutable attach = instructionOf(f.mod,
		find(f.mod, newRoot, "mizu.doir.attach_comptime_number_i64"));

	immutable a = addEntity(f.mod);
	immutable b = addEntity(f.mod);

	ComptimeProgram p;
	scope(exit) free(p);
	begin(p, f.mod, setModule);
	setCurrentEntity(p, a);
	ulong[2] first = [a, 11];
	call(p, attach, first[]);
	setCurrentEntity(p, b);
	ulong[2] second = [b, 22];
	call(p, attach, second[]);
	end(p);
	assert(run(p));

	assert(getComponent!ComptimeNumber(f.mod, a).value == 11);
	assert(getComponent!ComptimeNumber(f.mod, b).value == 22);
	diagnostics().clear();
}
