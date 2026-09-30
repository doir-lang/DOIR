/// `opt.mizu.comptimeEvaluate`: builds a tiny Mizu program that performs one
/// compile-time call, runs it, and lets the DOIR instructions write the
/// result back into the module. Ported from opt/mizu/comptime_evaluate.cpp.
module doir.pipeline.opt.mizu.comptime_evaluate;

import core.stdc.stdio : printf, snprintf;

import ecrs.storage : EntityId, invalidEntity;

static import fp.dynarray;
import fp.dynarray : daLength = length;

import mizu.opcode : setupEnvironment, startFromEnvironment;

import doir.byte_emiter;
import doir.interface_;
import doir.mizu.instructions : doirLookup;
import mizu.portable_format : fromPortable;
import doir.module_;
import doir.diagnostics : panic;
import doir.pipeline.canon.sort : newRoot, sortSuspended;
import doir.pipeline.opt.allocate_registers : beginRegisterAllocation, endRegisterAllocation;
import doir.string_helpers : InternedString, wildcardName;
import doir.systems : SystemFunction, fixedPointChanged;

@nogc nothrow:


/// Set while one call is being assembled, lowered and run, so that the pass
/// does not re-enter itself through the schedule it lowers with. A plain flag
/// rather than a depth count: there is nothing a nested evaluation could
/// usefully do, so the only question is in or out.
private __gshared bool evaluating;

/// True if `subtree` already has a value the compiler can read directly.
///
/// Through aliases (A-Transparent): `byte : alias = u8` is as available as
/// `u8`, and an argument spelled either way reaches the VM as the same entity
/// id. And a `TypeDefinition` counts on its own - a type built by an
/// instruction rather than declared `: type` has no `TypeOf` left to read.
///
/// A field of an aggregate counts too, and travels as its entity id the way a
/// type does: it names a position in a layout rather than a value, which is
/// what `mizu.doir.field_offset_bits` asks about.
bool comptimeValueAvailable(ref Module mod, EntityId subtree) {
	immutable compiler = resolveCached(mod, "compiler", 1, true);
	immutable type = resolveCached(mod, "type", 1, true);
	immutable blockType = resolveCached(mod, "block", 1, true);
	immutable e = resolveAlias(mod, subtree);

	return hasComponent!Number(mod, e) || hasComponent!DString(mod, e)
		|| hasComponent!ComptimeNumber(mod, e) || hasComponent!ComptimeString(mod, e)
		|| hasComponent!TypeDefinition(mod, e)
		|| isAggregateField(mod, e)
		|| (hasComponent!TypeOf(mod, e)
			&& (getComponent!TypeOf(mod, e).related[0] == type
				|| getComponent!TypeOf(mod, e).related[0] == blockType));
}

/// The `mizu.doir` names the throwaway program is assembled out of. Every one
/// of them is `invalidEntity` in a module that never early_include'd the
/// backend, and building the program anyway emitted bytes that decode to
/// nothing - which handed the VM a wild address, a segfault for any comptime
/// call in a module with no backend (a zero argument call is vacuously
/// comptime, so this is easy to reach).
private static immutable string[7] requiredForEvaluation = [
	"mizu",
	"mizu.u64",
	"mizu.halt",
	"mizu.load_immediate",
	"mizu.load_upper_immediate",
	"mizu.doir.set_module",
	"mizu.doir.attach_comptime_number_i64",
];

/// The instructions `comptimeEvaluate` must not run.
///
/// The program it builds holds one call and a `halt`, assembled fresh for
/// that one call - so an instruction that moves the program counter has
/// nowhere in *that* program to move to. `jump_to` is handed an address in
/// the real one (address 0, for a label whose instruction has not been
/// emitted yet), and the VM leaves for it, taking the compiler with it;
/// `find_label` is the other half of the same story, scanning the throwaway
/// program for a label that only exists in the real one and folding its
/// "not found" 0 back into the caller as though it were an address. `halt`
/// would end the program before it started, and a `label`'s value is
/// `opt.mizu.materializeLabels`' to hand out rather than anything the VM
/// computes.
private static immutable string[9] neverComptime = [
	"mizu.halt",
	"mizu.label",
	"mizu.find_label",
	"mizu.jump_relative",
	"mizu.jump_relative_immediate",
	"mizu.jump_to",
	"mizu.branch_relative",
	"mizu.branch_relative_immediate",
	"mizu.branch_to",
];

/// Evaluates `subtree` by assembling it into a throwaway block and running it
/// on the Mizu VM. `mizuSchedule` is the schedule that lowers that block -
/// any libECRS system, so the driver can hand over whatever it composed out of
/// `doir.systems`' walkers (see `doir.systems.moduleSystem` for turning one
/// into the function pointer this takes).
/// Everything `comptimeEvaluationPending` asks that is not about the
/// arguments: the flags, the position, and the callee.
private bool evaluableCall(ref Module mod, EntityId subtree) @trusted {
	if (!hasComponent!Call(mod, subtree)) return false;
	if (!flagsSet(mod, subtree, Flags.Comptime)) return false;

	// Not while another call is being evaluated. Lowering the throwaway block
	// runs the fallback schedule, which now holds this pass too, and the block
	// holds a comptime call by construction - so without this the first
	// evaluation would recurse into itself forever.
	if (evaluating) return false;

	// Not inside a function that has not been instantiated. A comptime call in
	// a body reads the body's *parameters*, which have no value until a call
	// site binds them - `std.execute(t)` on a `block` parameter used to abort in
	// `inlineInto`, since a parameter has no `Block` to splice.
	// `opt.inlineFunctions` substitutes the arguments in, and this pass runs
	// after it (see `mizuSchedule`), which is when such a call can be run.
	// `opt.computeShiftRight` declines the same way and for the same reason.
	if (findFunctionInsideOf(mod, subtree)) return false;

	immutable calledFunction = resolveAlias(mod, getComponent!Call(mod, subtree).related[0]);
	// Nothing to run if the call has no target. `invalidEntity` is 0, so
	// leaving this open would also let an unresolved callee compare equal to
	// any `mizu.*` name this module never resolved.
	if (calledFunction == invalidEntity) return false;
	// Nor is there anything to run when the callee was only declared.
	// `standard.doir` is almost entirely such declarations.
	if (flagsSet(mod, calledFunction, Flags.Valueless)) return false;

	immutable calleeParent = findParent(mod, calledFunction);
	// Compiler functions have their own pass and shouldn't really be used
	// outside of the mizu backend.
	if (calleeParent == resolveCached(mod, "compiler", 1, true)
		|| calleeParent == resolveCached(mod, "compiler.assembler", 1, true))
		return false;

	foreach (name; neverComptime)
		if (calledFunction == resolveCached(mod, name, 1, true)) return false;

	// A callee whose type says it emits rather than computes. `sema.bubbleComptime`
	// clears the mark for the same reason, and asking again here is not belt and
	// braces: the two passes are in one `fixedPoint`, and within a round
	// `bubbleComptime` walks the whole module before this one does. A modifier
	// call that sets the flag - `std.functions.never_comptime(if_t)` - is folded by
	// *this* walk, so in the round that sets it `bubbleComptime` has already been
	// past with the flag still absent, and the call it marked comptime is standing
	// right there. `std.if` was evaluated exactly once that way, which was once too
	// many: the throwaway block is assembled out of the branch instructions `if`
	// exists to emit.
	if (hasComponent!TypeOf(mod, calledFunction)
		&& flagsSet(mod, resolveAlias(mod, getComponent!TypeOf(mod, calledFunction).related[0]),
			Flags.NoComptime))
		return false;

	// And nothing is pending in a module with no mizu backend loaded: every name
	// the throwaway program is assembled out of is `invalidEntity` there, so
	// there is no program to run. `comptimeEvaluate` checked this on its own and
	// declined, which was too late once `opt.inlineFunctions` started asking -
	// it left a call that this pass was never going to fold and that pass had
	// stood down for.
	foreach (name; requiredForEvaluation)
		if (resolveCached(mod, name, 1, true) == invalidEntity) return false;

	return true;
}

/// Whether `subtree` is the evaluator's - a comptime call it is entitled to
/// run - whether or not it can run it yet, and whether or not it already has.
///
/// Public because `opt.inlineFunctions` asks, and this rather than
/// `comptimeEvaluationPending` is the question that pass has. A call the
/// evaluator owns must not be inlined out from under it: inlining replaces the
/// call with its body, and the body of a `mizu.doir` instruction is the *bytes
/// of that instruction*, which in the emitted program would mean editing the
/// entity store at runtime.
///
/// The two questions came apart over a chain. One `depthFirst` walk of the
/// evaluator folds a whole chain, because post-order reaches an argument
/// before the call that reads it - but the inliner runs before any of that, so
/// when it asks, every link past the first still has an unfolded call for an
/// argument. Asking `comptimeEvaluationPending` there answered "not runnable,
/// inline it" and cost the chain every link but the innermost: `std.add`'s
/// dispatch reads its type's tag, compares it, and only then has a condition
/// to pick a block with, and it was the comparison that went. So an argument
/// that is itself a claimed call counts as one the evaluator will supply.
///
/// Only such an argument, which is why this is not simply
/// `comptimeEvaluationPending` without its argument check. `mizu.emit_register`
/// is a comptime call whose argument is a `compiler.assembler.return_register`
/// - folded by `opt.computeCompilerNamespace`, never by the evaluator, which
/// declines the whole `compiler` namespace - and standing down for that one
/// left every instruction in `mizu.doir` two bytes short of its operand.
///
/// An already-folded call is still claimed. The evaluator leaves the `Call`
/// where it was and hangs the answer off it as a `ComptimeNumber`, so nothing
/// else marks it done - and a schedule that runs the inliner again afterwards
/// (`standard.mizu.doir`'s does, for `materializeLabels`) would otherwise
/// replace a call whose value is known with the instruction that computes it.
bool comptimeEvaluationClaims(ref Module mod, EntityId subtree, size_t depth = 8) @trusted {
	if (!evaluableCall(mod, subtree)) return false;

	if (hasComponent!FunctionInputs(mod, subtree)) {
		auto inputs = &getComponent!FunctionInputs(mod, subtree);
		foreach (i; 0 .. daLength(inputs.related)) {
			immutable e = resolveAlias(mod, inputs.related[i]);
			if (comptimeValueAvailable(mod, e)) continue;
			// Bounded rather than exhaustive: arguments form a DAG (SSA), so
			// this terminates either way, and a chain longer than this asks
			// the inliner to stand down for a fold several rounds out, which
			// it has no schedule to wait for.
			if (depth > 0 && comptimeEvaluationClaims(mod, e, depth - 1)) continue;
			return false;
		}
	}

	return true;
}

/// Whether this pass still owes `subtree` an answer: a call it owns, has not
/// run yet, and has every argument for *now*.
bool comptimeEvaluationPending(ref Module mod, EntityId subtree) @trusted {
	if (!evaluableCall(mod, subtree)) return false;

	// Already folded. Not `comptimeValueAvailable`: its `TypeOf == type` clause
	// is about *arguments* - a type entity passed to a call is a value the
	// compiler can read - and `subtree` here is the call. Asking it of the call
	// as well made every declaration whose result is a type unevaluable, which
	// is every modifier there is: M-Flag's whole signature is
	// `(in: type) -> type`.
	if (hasComponent!Number(mod, subtree) || hasComponent!DString(mod, subtree)
		|| hasComponent!ComptimeNumber(mod, subtree) || hasComponent!ComptimeString(mod, subtree))
		return false;

	if (hasComponent!FunctionInputs(mod, subtree)) {
		auto inputs = &getComponent!FunctionInputs(mod, subtree);
		foreach (i; 0 .. daLength(inputs.related))
			if (!comptimeValueAvailable(mod, inputs.related[i])) return false;
	}

	return true;
}

bool comptimeEvaluate(ref Module mod, EntityId subtree, SystemFunction mizuSchedule) @trusted {
	if (!comptimeEvaluationPending(mod, subtree)) return true;

	immutable calledFunction = resolveAlias(mod, getComponent!Call(mod, subtree).related[0]);

	immutable compiler = resolveCached(mod, "compiler", 1, true);
	immutable type = resolveCached(mod, "type", 1, true);
	immutable blockType = resolveCached(mod, "block", 1, true);
	immutable voidType = resolveCached(mod, "void", 1, true);
	immutable earlyInclude = resolveCached(mod, "early_include", 5, true);

	immutable compilerCurrentEntity = resolveCached(mod, "compiler.current_entity", 1, true);
	immutable assemblerPinRegister = resolveCached(mod, "compiler.assembler.pin_register", 1, true);
	immutable assemblerRegister = resolveCached(mod, "compiler.assembler.register", 1, true);

	immutable mizuNs = resolveCached(mod, "mizu", 1, true);
	immutable mizuU64 = resolveCached(mod, "mizu.u64", 1, true);
	immutable mizuHalt = resolveCached(mod, "mizu.halt", 1, true);
	immutable mizuLoadImmediate = resolveCached(mod, "mizu.load_immediate", 1, true);
	immutable mizuLoadUpperImmediate = resolveCached(mod, "mizu.load_upper_immediate", 1, true);
	immutable mizuDoirSetModule = resolveCached(mod, "mizu.doir.set_module", 1, true);
	immutable mizuDoirAttachComptimeNumberI64 =
		resolveCached(mod, "mizu.doir.attach_comptime_number_i64", 1, true);

	// Every one of these is needed to assemble the throwaway program below, and
	// every one of them is `invalidEntity` (0) in a module that never
	// early_include'd mizu.doir. Building the block anyway emitted bytes that
	// decode to nothing, and `startFromEnvironment` then jumped the VM into a
	// wild address - a segfault for any comptime call in a module with no mizu
	// backend loaded (a zero-argument call is vacuously comptime, so this is
	// easy to reach). Leave the call alone instead, the way a `compiler.*`
	// callee is left alone above.
	if (mizuNs == invalidEntity || mizuU64 == invalidEntity || mizuHalt == invalidEntity
		|| mizuLoadImmediate == invalidEntity || mizuLoadUpperImmediate == invalidEntity
		|| mizuDoirSetModule == invalidEntity
		|| mizuDoirAttachComptimeNumberI64 == invalidEntity)
		return true;

	getComponent!Number(mod, compilerCurrentEntity).value = subtree;

	fixedPointChanged() = true;

	auto comptimeBlock = createBlockBuilder(mod);
	{
		auto related = &getComponent!Block(mod, comptimeBlock.block).related;
		fp.dynarray.pushBack(*related, type);
		fp.dynarray.pushBack(*related, voidType);
		fp.dynarray.pushBack(*related, earlyInclude);
		fp.dynarray.pushBack(*related, compiler);
		fp.dynarray.pushBack(*related, mizuNs);
	}

	immutable modPtr = cast(size_t) &mod;
	auto currentModule = pushNumber(comptimeBlock, InternedString("_"), mizuU64, cast(uint) modPtr);
	size_t rValue = 1;
	// Two since the allocator tends to skip 2.
	auto r = pushNumber(comptimeBlock, InternedString("_"), assemblerRegister, rValue++);
	{
		EntityId[3] inputs = [mizuU64, currentModule, r];
		pushCall(comptimeBlock, InternedString("_"), assemblerRegister, assemblerPinRegister, inputs[]);
	}
	{
		EntityId[2] inputs = [mizuU64, currentModule];
		pushCall(comptimeBlock, InternedString("_"), assemblerRegister, mizuLoadImmediate, inputs[]);
	}
	currentModule = pushNumber(comptimeBlock, InternedString("_"), mizuU64, cast(uint)(modPtr >> 32));
	{
		EntityId[3] inputs = [mizuU64, currentModule, r];
		pushCall(comptimeBlock, InternedString("_"), assemblerRegister, assemblerPinRegister, inputs[]);
	}
	{
		EntityId[2] inputs = [mizuU64, currentModule];
		pushCall(comptimeBlock, InternedString("_"), assemblerRegister, mizuLoadUpperImmediate, inputs[]);
	}
	{
		EntityId[1] inputs = [currentModule];
		pushCall(comptimeBlock, InternedString("_"), assemblerRegister, mizuDoirSetModule, inputs[]);
	}

	auto currentEntity = pushNumber(comptimeBlock, InternedString("_"), mizuU64, subtree);
	r = pushNumber(comptimeBlock, InternedString("_"), assemblerRegister, rValue++);
	{
		EntityId[2] inputs = [mizuU64, currentEntity];
		pushCall(comptimeBlock, InternedString("_"), assemblerRegister, mizuLoadImmediate, inputs[]);
	}
	{
		EntityId[3] inputs = [mizuU64, currentEntity, r];
		pushCall(comptimeBlock, InternedString("_"), assemblerRegister, assemblerPinRegister, inputs[]);
	}

	EntityId* arguments;
	scope(exit) fp.dynarray.free(arguments);
	if (hasComponent!FunctionInputs(mod, subtree)) {
		immutable count = daLength(getComponent!FunctionInputs(mod, subtree).related);
		foreach (i; 0 .. count) {
			auto e = resolveAlias(mod, getComponent!FunctionInputs(mod, subtree).related[i]);

			// Named by position, never after the argument it carries. Two
			// slots can hold the same entity (`mizu.add(a, a)`) or two
			// same-named ones, and naming them after their argument put two
			// children with one name in this block - which is a redefinition to
			// anything that walks it, `sema.nameReuse` included, now that the
			// backend runs that as part of lowering.
			InternedString name;
			{
				char[24] buffer;
				immutable n = snprintf(buffer.ptr, buffer.length, "a%zu", i);
				name = internIn(mod, buffer[0 .. n]);
			}

			size_t value;
			if (hasComponent!Number(mod, e))
				value = cast(size_t) getComponent!Number(mod, e).value;
			else if (hasComponent!ComptimeNumber(mod, e))
				value = cast(size_t) getComponent!ComptimeNumber(mod, e).value;
			else if (hasComponent!DString(mod, e))
				value = cast(size_t) getComponent!DString(mod, e).value.view.ptr;
			else if (hasComponent!ComptimeString(mod, e))
				value = cast(size_t) getComponent!ComptimeString(mod, e).value.view.ptr;
			// A type is passed as its entity id, which is what makes
			// `mizu.doir`'s reflection instructions work on a plain register.
			// `TypeDefinition` as well as `TypeOf == type`: an instruction that
			// builds a type leaves the definition and no declared type.
			else if (hasComponent!TypeDefinition(mod, e)
				|| (hasComponent!TypeOf(mod, e)
					&& (getComponent!TypeOf(mod, e).related[0] == blockType
						|| getComponent!TypeOf(mod, e).related[0] == type)))
				value = resolveAlias(mod, e);
			// A field of an aggregate travels as its entity id for the same
			// reason a type does: it names a position in a layout rather than a
			// value, and `mizu.doir.field_offset_bits` asks the store where.
			else if (isAggregateField(mod, e))
				value = resolveAlias(mod, e);
			else
				panic("Comptime evaluation of call with non-comptime parameter");

			// Low half first, then the upper one into the same register, the
			// way the `Module*` above is loaded. A Mizu immediate is 32 bits
			// (`opt.mizu.materializeImmediates` casts to `uint`), and a single
			// `load_immediate` per argument silently truncated every value that
			// did not fit - which is every *pointer*, so a string argument
			// reached an instruction as a wild address.
			e = pushNumber(comptimeBlock, name, mizuU64, cast(uint) value);
			{
				EntityId[2] inputs = [mizuU64, e];
				pushCall(comptimeBlock, InternedString("_"), assemblerRegister, mizuLoadImmediate, inputs[]);
			}
			r = pushNumber(comptimeBlock, InternedString("_"), assemblerRegister, rValue++);
			{
				EntityId[3] inputs = [mizuU64, e, r];
				pushCall(comptimeBlock, InternedString("_"), assemblerRegister, assemblerPinRegister, inputs[]);
			}
			if (value >> 32) {
				InternedString upperName;
				{
					char[24] buffer;
					immutable n = snprintf(buffer.ptr, buffer.length, "a%zu_upper", i);
					upperName = internIn(mod, buffer[0 .. n]);
				}
				immutable upper = pushNumber(comptimeBlock, upperName, mizuU64, cast(uint)(value >> 32));
				{
					EntityId[3] inputs = [mizuU64, upper, r];
					pushCall(comptimeBlock, InternedString("_"), assemblerRegister, assemblerPinRegister, inputs[]);
				}
				{
					EntityId[2] inputs = [mizuU64, upper];
					pushCall(comptimeBlock, InternedString("_"), assemblerRegister, mizuLoadUpperImmediate, inputs[]);
				}
			}
			fp.dynarray.pushBack(arguments, e);
		}
	}

	immutable typeOfSubtree = resolveAlias(mod, getComponent!TypeOf(mod, subtree).related[0]);
	auto name = hasComponent!Name(mod, subtree)
		? getComponent!Name(mod, subtree).value
		: wildcardName();
	auto ret = pushCall(comptimeBlock, name, typeOfSubtree, calledFunction, fp.dynarray.slice(arguments));
	r = pushNumber(comptimeBlock, InternedString("_"), assemblerRegister, rValue++);
	{
		EntityId[3] inputs = [mizuU64, ret, r];
		pushCall(comptimeBlock, InternedString("_"), assemblerRegister, assemblerPinRegister, inputs[]);
	}

	// TODO: Store back string
	{
		EntityId[2] inputs = [currentEntity, ret];
		pushCall(comptimeBlock, InternedString("_"), mizuU64, mizuDoirAttachComptimeNumberI64, inputs[]);
	}

	{
		EntityId[0] none;
		pushCall(comptimeBlock, InternedString("_"), mizuU64, mizuHalt, none[]);
	}

	// printf("Comptime evaluating: %u\n", subtree);

	evaluating = true;
	scope(exit) evaluating = false;

	immutable backup = newRoot;
	newRoot = comptimeBlock.block;
	// Every id here - `comptimeBlock.block`, `backup`, and every id the walk
	// that reached this call is holding - is an id in the module, and a sort
	// renumbers all of them. See `canon.sort.sortSuspended`.
	sortSuspended = true;
	immutable lowered = mizuSchedule(mod.ctx);
	sortSuspended = false;
	newRoot = backup;

	// A lowering schedule that failed has raised its diagnostic, and the stage
	// hook ends the compile on the way out of this walk. Carrying on would run
	// the VM over a block the schedule did not finish lowering, and - since
	// this is reached once per comptime call, with the failure the same every
	// time - would raise that one diagnostic again for every call in the
	// module before anything looked at it.
	if (!lowered) return false;

	auto bytes = emitAll(mod, comptimeBlock.block);
	scope(exit) fp.dynarray.free(bytes);

	{
		auto portable = fromPortable!doirLookup(fp.dynarray.slice(bytes));
		scope(exit) if (portable.program !is null) fp.dynarray.free(portable.program);

		immutable count = daLength(portable.program);
		// Nothing decoded - there is no entry point to jump to, and handing the
		// VM a null program counter runs whatever happens to be at address 0.
		if (count == 0) return true;
		setupEnvironment(portable.environment, portable.program, portable.program + count);
		startFromEnvironment(portable.program, portable.environment);
	}

	// An instruction may have spliced source into the call it replaced rather
	// than handing back a number - `mizu.doir.execute` is the whole reason this
	// pass runs inside the lowering schedule at all. What it splices is a copy
	// of what the program *wrote*, so it has had none of the lowering the code
	// around it has: no registers, no materialized immediates, its own calls
	// still calls. Lower it the same way the block above was, which is also the
	// same way the module around it is (C-Lower).
	//
	// `evaluating` is still set, so this walk will not try to evaluate anything
	// it finds. That is the intent: the spliced code is the program's, to be
	// emitted, not more compile time work to do.
	if (hasComponent!Block(mod, subtree)) {
		immutable splicedBackup = newRoot;
		newRoot = subtree;
		sortSuspended = true;
		// The walk starts inside the module rather than at its root, so it never
		// meets the `begin_register_allocation` call that would otherwise turn
		// allocation on - and spliced code needs registers exactly like the code
		// around it.
		immutable wasAllocating = beginRegisterAllocation();
		immutable ok = mizuSchedule(mod.ctx);
		endRegisterAllocation(wasAllocating);
		sortSuspended = false;
		newRoot = splicedBackup;
		if (!ok) return false;
	}

	return true;
}


// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
//
// The ordinary path runs whenever a program calls a `mizu.*` function at
// compile time (see `doir.pipeline`'s end-to-end tests). What is left here is
// the argument shapes those programs happen not to use: a string constant, an
// already-evaluated comptime string, and an argument with no name of its own.

version (unittest) {
	import doir.pipeline : mizuSchedule;
	import doir.diagnostics : diagnostics;
	import doir.systems : moduleSystem;
	import tests.pipeline_helper : compile, PipelineResult, withMizu;


	/// `mizu.add(a, b)`, marked comptime, pushed into the fixture's root.
	private EntityId pushComptimeAdd(ref PipelineResult f, const(EntityId)[] args) {
		auto block = BlockBuilder(f.root, &f.mod);
		immutable u64 = resolveLookupName(f.mod, internIn(f.mod, "mizu.u64"), f.root);
		immutable add = resolveLookupName(f.mod, internIn(f.mod, "mizu.add"), f.root);
		assert(u64 != invalidEntity && add != invalidEntity);

		immutable call = pushCall(block, InternedString("_"), u64, add, args);
		getOrAddComponent!Flags(f.mod, call).flags |= Flags.Comptime;
		return call;
	}
}

unittest { // a string constant is passed to the VM as the address of its bytes
	auto f = withMizu("comptime.doir");
	scope(exit) freeModule(f.mod);

	auto block = BlockBuilder(f.root, &f.mod);
	immutable bytePointer = resolveLookupName(f.mod,
		internIn(f.mod, "compiler.byte_pointer"), f.root);
	immutable s = pushString(block, internIn(f.mod, "s"), bytePointer, internIn(f.mod, "hi"));

	EntityId[2] args = [s, s];
	immutable call = pushComptimeAdd(f, args[]);
	assert(comptimeEvaluate(f.mod, call, &moduleSystem!mizuSchedule));
	assert(!diagnostics().hasErrors());
	diagnostics().clear();
}

unittest { // ...and so is one that an earlier round already evaluated
	auto f = withMizu("comptime.doir");
	scope(exit) freeModule(f.mod);

	auto block = BlockBuilder(f.root, &f.mod);
	immutable bytePointer = resolveLookupName(f.mod,
		internIn(f.mod, "compiler.byte_pointer"), f.root);
	immutable s = pushValueless(block, internIn(f.mod, "s"), bytePointer);
	addComponent!ComptimeString(f.mod, s).value = internIn(f.mod, "hi");

	EntityId[2] args = [s, s];
	immutable call = pushComptimeAdd(f, args[]);
	assert(comptimeEvaluate(f.mod, call, &moduleSystem!mizuSchedule));
	assert(!diagnostics().hasErrors());
	diagnostics().clear();
}

unittest { // an argument with no name of its own gets a generated one
	auto f = withMizu("comptime.doir");
	scope(exit) freeModule(f.mod);

	auto block = BlockBuilder(f.root, &f.mod);
	immutable u64 = resolveLookupName(f.mod, internIn(f.mod, "mizu.u64"), f.root);
	// `_` is the discard name, which `pushCommon` attaches no `Name` for.
	immutable anonymous = pushNumber(block, InternedString("_"), u64, 3);
	assert(!hasComponent!Name(f.mod, anonymous));

	EntityId[2] args = [anonymous, anonymous];
	immutable call = pushComptimeAdd(f, args[]);
	assert(comptimeEvaluate(f.mod, call, &moduleSystem!mizuSchedule));
	assert(!diagnostics().hasErrors());
	diagnostics().clear();
}

unittest { // calls the evaluator has nothing to do with are left alone
	auto f = withMizu("comptime.doir");
	scope(exit) freeModule(f.mod);

	auto block = BlockBuilder(f.root, &f.mod);
	immutable u64 = resolveLookupName(f.mod, internIn(f.mod, "mizu.u64"), f.root);
	immutable byte_ = resolveLookupName(f.mod, internIn(f.mod, "compiler.byte"), f.root);
	immutable emit = resolveLookupName(f.mod, internIn(f.mod, "compiler.emit"), f.root);
	immutable halt = resolveLookupName(f.mod, internIn(f.mod, "mizu.halt"), f.root);

	immutable n = pushNumber(block, internIn(f.mod, "n"), byte_, 1);
	assert(comptimeEvaluate(f.mod, n, &moduleSystem!mizuSchedule)); // not a call

	// A call that is not marked comptime.
	immutable runtime = pushCall(block, internIn(f.mod, "r"), byte_, emit, (&n)[0 .. 1]);
	assert(comptimeEvaluate(f.mod, runtime, &moduleSystem!mizuSchedule));
	assert(hasComponent!Call(f.mod, runtime));

	// A `compiler.*` callee, which has its own pass.
	getOrAddComponent!Flags(f.mod, runtime).flags |= Flags.Comptime;
	assert(comptimeEvaluate(f.mod, runtime, &moduleSystem!mizuSchedule));
	assert(hasComponent!Call(f.mod, runtime));

	// `mizu.halt`, which would end the throwaway program before it started.
	EntityId[0] none;
	immutable haltCall = pushCall(block, InternedString("_"), u64, halt, none[]);
	getOrAddComponent!Flags(f.mod, haltCall).flags |= Flags.Comptime;
	assert(comptimeEvaluate(f.mod, haltCall, &moduleSystem!mizuSchedule));
	assert(hasComponent!Call(f.mod, haltCall));

	// A call whose target never resolved.
	immutable dangling = pushCommon(f.mod, f.root, InternedString("_"));
	addComponent!TypeOf(f.mod, dangling).related[0] = u64;
	addComponent!Call(f.mod, dangling).related[0] = invalidEntity;
	getOrAddComponent!Flags(f.mod, dangling).flags |= Flags.Comptime;
	assert(comptimeEvaluate(f.mod, dangling, &moduleSystem!mizuSchedule));

	assert(!diagnostics().hasErrors());
	diagnostics().clear();
}

unittest {
	// `comptimeEvaluationClaims` is the weaker question, and it is
	// `opt.inlineFunctions`' one: a chain of comptime calls is folded innermost
	// first, so when the inliner asks, every link past the first still has an
	// unfolded call for an argument. Answering with `comptimeEvaluationPending`
	// left the inliner free to replace the outer link with the bytes of the
	// instruction that computes it, which is what cost `std.add`'s dispatch its
	// comparison.
	auto f = withMizu("claims.doir");
	scope(exit) freeModule(f.mod);

	auto block = BlockBuilder(f.root, &f.mod);
	immutable byte_ = resolveLookupName(f.mod, internIn(f.mod, "compiler.byte"), f.root);
	immutable n = pushNumber(block, internIn(f.mod, "n"), byte_, 1);

	EntityId[2] leaf = [n, n];
	immutable inner = pushComptimeAdd(f, leaf[]);
	assert(comptimeEvaluationPending(f.mod, inner));
	assert(comptimeEvaluationClaims(f.mod, inner));

	// The outer call cannot run - `inner` has no value yet - but it is still
	// the evaluator's, because `inner` is.
	EntityId[2] chained = [inner, inner];
	immutable outer = pushComptimeAdd(f, chained[]);
	assert(!comptimeEvaluationPending(f.mod, outer));
	assert(comptimeEvaluationClaims(f.mod, outer));

	// Not every unfolded argument, though. A `compiler.assembler.*` call is
	// `opt.computeCompilerNamespace`'s to fold and never the evaluator's, so a
	// call reading one has to be inlined rather than waited for - which is
	// every instruction encoder in `mizu.doir`, each of them reading a
	// `return_register`.
	immutable returnRegister = resolveLookupName(f.mod,
		internIn(f.mod, "compiler.assembler.return_register"), f.root);
	immutable registerType = resolveLookupName(f.mod,
		internIn(f.mod, "compiler.assembler.register"), f.root);
	EntityId[1] typeArg = [resolveLookupName(f.mod, internIn(f.mod, "mizu.u64"), f.root)];
	immutable regret = pushCall(block, internIn(f.mod, "regret"), registerType,
		returnRegister, typeArg[]);
	getOrAddComponent!Flags(f.mod, regret).flags |= Flags.Comptime;

	EntityId[2] viaRegister = [regret, regret];
	immutable reader = pushComptimeAdd(f, viaRegister[]);
	assert(!comptimeEvaluationPending(f.mod, reader));
	assert(!comptimeEvaluationClaims(f.mod, reader));

	assert(!diagnostics().hasErrors());
	diagnostics().clear();
}

unittest { // a module with no mizu backend loaded evaluates nothing
	import tests.pipeline_helper : makeModuleWithBuiltins;

	auto f = makeModuleWithBuiltins();
	scope(exit) freeModule(f.mod);
	diagnostics().clear();

	auto block = BlockBuilder(f.root, &f.mod);
	immutable byte_ = resolveLookupName(f.mod, internIn(f.mod, "compiler.byte"), f.root);
	// A zero-argument call is vacuously comptime, and nothing `mizu.*` the
	// evaluator needs exists here - so it has to bail out rather than assemble
	// a program out of `invalidEntity`s and jump the VM into it.
	immutable emitT = resolveLookupName(f.mod, internIn(f.mod, "compiler.emit_t"), f.root);
	EntityId[0] none;
	immutable call = pushCall(block, internIn(f.mod, "c"), byte_, emitT, none[]);
	getOrAddComponent!Flags(f.mod, call).flags |= Flags.Comptime;

	assert(comptimeEvaluate(f.mod, call, &moduleSystem!mizuSchedule));
	assert(hasComponent!Call(f.mod, call));
	assert(!diagnostics().hasErrors());
	diagnostics().clear();
}

unittest {
	// A jump handed a compile-time constant is still a jump. It used to be
	// assembled into the throwaway program and *run*: the VM left for
	// whatever address the constant named - 0, here - and took the compiler
	// down with it, so the crash was the compiler's rather than the compiled
	// program's. It belongs in the output instead.
	auto r = compile(
		"path : compiler.byte_pointer = \"./mizu.doir\"\n"
		~ "_ : compiler.byte = early_include(path)\n"
		~ "_ : compiler.assembler.register = compiler.assembler.begin_register_allocation()\n"
		~ "a : mizu.u64 = 0\n"
		~ "_ : mizu.u64 = mizu.jump_to(a)\n"
		~ "_ : mizu.u64 = mizu.halt()\n");
	scope(exit) freeModule(r.mod);
	assert(r.ok);
	diagnostics().clear();
}
