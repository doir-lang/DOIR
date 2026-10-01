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
import mizu.opcode : Reg;

import doir.comptime.program;
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
///
/// A parameter never counts, whatever it is declared as. This is the whole of
/// what the pass used to say by refusing every call inside a function body: a
/// parameter is a name a call site binds, and until one does there is nothing
/// to read. The two clauses below that go by declared type would otherwise
/// take one on trust - a `T: type` or a `blk: block` parameter looks exactly
/// like the argument that will replace it - and `std.execute(blk)` on one
/// aborted in `inlineInto`, a parameter having no `Block` to splice.
/// `opt.inlineFunctions` substitutes the arguments in, and from then on
/// `resolveAlias` lands on the argument rather than the parameter.
bool comptimeValueAvailable(ref Module mod, EntityId subtree) {
	immutable compiler = resolveCached(mod, "compiler", 1, true);
	immutable type = resolveCached(mod, "type", 1, true);
	immutable blockType = resolveCached(mod, "block", 1, true);
	immutable e = resolveAlias(mod, subtree);

	if (hasComponent!FunctionParameter(mod, e)) return false;

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

/// The instructions `comptimeEvaluate` must not run and that cannot say so on
/// their own type.
///
/// Every other one does: `mizu.doir` declares `_effect_t` twins of its
/// instruction shapes carrying `compiler.no_comptime`, and `sema.bubbleComptime`
/// will not mark a call whose callee's type has that flag - which is the right
/// place for it, since whether a call may be folded is a property of its
/// callee, and an alias such as `std.jump_to` inherits a type for free where it
/// would not match a name here.
///
/// `mizu.label` is what is left. It is declared with an anonymous function
/// type (`() -> compiler.assembler.register`), so there is nothing to hang a
/// flag on, and its value is `opt.mizu.materializeLabels`' to hand out rather
/// than anything the VM computes.
private static immutable string[1] neverComptime = [
	"mizu.label",
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

	// Nothing here about being inside a function body. What that used to stand
	// for - a body's parameters have no value until a call site binds them -
	// `comptimeValueAvailable` now says exactly, and the difference is a body
	// nothing inlines: `opt.liftFunctionBodies` emits one, so the dispatch
	// inside it has to fold the way the same dispatch does at module scope.

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

// ---------------------------------------------------------------------------
// Regions
// ---------------------------------------------------------------------------
//
// A *region* is a connected set of comptime calls the evaluator runs as one
// Mizu program: the call asked about, every call that feeds it an argument,
// and so on inward. The alternative - and what this pass used to be - is one
// program per call, each one folding its result into the store so that the
// call above it has a constant to read on a later round of the fixpoint.
//
// One program per region is not an optimization. `opt.inlineFunctions` runs
// before this pass and has to be told which calls to leave alone, and with one
// program per call that question had no honest answer: nothing is folded when
// the inliner asks, so "can the evaluator run this?" was false for every link
// of a chain but the innermost, and the pass answered with a *prediction*
// instead - every argument is available now or is itself a predicted call, to
// a depth of eight. The inliner acts on the answer irrevocably, so a call that
// was predicted and then never became runnable was stranded: never inlined,
// never folded. Which of the two passes won came down to entity numbering.
//
// A region makes the question answerable. The evaluator commits to running the
// whole set, so an argument that is itself an owned call is one it *will*
// supply rather than one it hopes somebody folds first, and "claimed" and
// "will be folded" become the same predicate - exact, and with no depth bound,
// since the argument graph is acyclic (see @comptime's note).

/// How many calls one region may hold.
///
/// Each call's result has to stay live until everything that reads it has run,
/// so the register file is the limit. A region that would go over is declined
/// rather than split: the outer call then folds on a later round of the
/// fixpoint, once this one has folded its arguments - which is the old
/// one-call-at-a-time behaviour, kept as the fallback for programs big enough
/// to need it.
private enum size_t maximumRegionSize = maximumResults;

/// Where `collectRegion` builds.
///
/// One array reused rather than one per question: `opt.inlineFunctions` asks
/// `comptimeEvaluationClaims` once per call in the module, and the answer is
/// usually "no", so a fresh allocation per question is a lot of malloc for a
/// walk that touches nothing.
private __gshared EntityId* regionScratch;

/// A comptime call this pass is entitled to run: everything `evaluableCall`
/// asks, and a callee that bottoms out in a Mizu instruction.
///
/// The second half is what the old one-program-per-call path discovered by
/// building a program that decoded to nothing and jumping the VM into it.
private bool ownedCall(ref Module mod, EntityId subtree) @trusted {
	if (!evaluableCall(mod, subtree)) return false;
	immutable callee = resolveAlias(mod, getComponent!Call(mod, subtree).related[0]);
	return instructionOf(mod, callee) !is null;
}

/// Collects the region rooted at `subtree` into `region`, arguments before the
/// call that reads them, and answers whether it is complete - whether every
/// argument is either a value the compiler can read now or another call in the
/// region.
///
/// Incomplete is not an error. An argument that is neither is one somebody else
/// folds - `opt.computeCompilerNamespace` does the whole `compiler` namespace,
/// and `mizu.emit_register` takes a `compiler.assembler.return_register` - or
/// one that is genuinely a runtime value, and in both cases the call belongs to
/// the inliner rather than here.
/// Set by `collectRegion` when the one thing standing between a region and
/// running it is a parameter nothing has bound yet. Sticky until an entry point
/// clears it, which is how a refusal deep in the recursion reaches the top.
private __gshared bool regionDeferred;

private bool collectRegion(ref Module mod, EntityId subtree, ref EntityId* region) @trusted {
	if (!ownedCall(mod, subtree)) return false;

	// A DAG rather than a tree: two calls can read the same argument, and the
	// second reader must not append it again - the program would run it twice,
	// and the second run would see a store the first had already edited.
	foreach (i; 0 .. daLength(region))
		if (region[i] == subtree) return true;

	// Both the register budget and the only thing standing between a malformed
	// store and an infinite recursion: nothing is appended until the arguments
	// are done, so depth is bounded by length only because of this.
	if (daLength(region) >= maximumRegionSize) return false;

	if (hasComponent!FunctionInputs(mod, subtree)) {
		auto inputs = &getComponent!FunctionInputs(mod, subtree);
		foreach (i; 0 .. daLength(inputs.related)) {
			immutable a = resolveAlias(mod, inputs.related[i]);
			if (comptimeValueAvailable(mod, a)) continue;
			// Not incomplete, just early. See `comptimeEvaluationClaims`.
			if (hasComponent!FunctionParameter(mod, a)) {
				regionDeferred = true;
				return false;
			}
			if (!collectRegion(mod, a, region)) return false;
		}
	}

	fp.dynarray.pushBack(region, subtree);
	return true;
}

/// Whether `subtree` is the evaluator's - a comptime call it will run, and
/// which `opt.inlineFunctions` must therefore leave alone.
///
/// Inlining replaces a call with its body, and the body of a `mizu.doir`
/// instruction is the *bytes of that instruction*, which in the emitted
/// program would mean editing the compiler's entity store at runtime.
///
/// An already-folded call is still claimed. The evaluator leaves the `Call`
/// where it was and hangs the answer off it as a `ComptimeNumber`, so nothing
/// else marks it done - and a schedule that runs the inliner again afterwards
/// (`standard.mizu.doir`'s does, for `materializeLabels`) would otherwise
/// replace a call whose value is known with the instruction that computes it.
///
/// So is a region waiting on a parameter, which cannot run yet and must still
/// be left alone. A function body is a template: `std.subtract`'s own
/// declaration holds the `kind` -> condition -> `execute_if` chain written
/// against its parameter `T`, and inlining copies that body to each call site.
/// Inline the chain in the template and every copy made afterwards carries the
/// bytes of the instruction that computes `kind` instead of the call that
/// folds to it - so whether the dispatch collapses came down to whether the
/// inliner reached a call site before it reached the declaration. It reached
/// `test.doir`'s top level first and `std.while`'s body second, which is
/// exactly the shape the divergence had.
bool comptimeEvaluationClaims(ref Module mod, EntityId subtree) @trusted {
	if (!ownedCall(mod, subtree)) return false;
	fp.dynarray.clear(regionScratch);
	regionDeferred = false;
	if (collectRegion(mod, subtree, regionScratch)) return true;
	return regionDeferred;
}

/// Whether the evaluator has already answered this call.
///
/// Not `comptimeValueAvailable`: its `TypeOf == type` clause is about
/// *arguments* - a type entity passed to a call is a value the compiler can
/// read - and this is asked of the call. Asking it of the call as well made
/// every declaration whose result is a type unevaluable, which is every
/// modifier there is: M-Flag's whole signature is `(in: type) -> type`.
private bool alreadyFolded(ref Module mod, EntityId subtree) {
	return hasComponent!Number(mod, subtree) || hasComponent!DString(mod, subtree)
		|| hasComponent!ComptimeNumber(mod, subtree)
		|| hasComponent!ComptimeString(mod, subtree);
}

/// Whether this pass still owes `subtree` an answer: a call it claims and has
/// not run yet.
bool comptimeEvaluationPending(ref Module mod, EntityId subtree) @trusted {
	if (alreadyFolded(mod, subtree)) return false;
	if (!ownedCall(mod, subtree)) return false;
	// Complete, not merely claimed: a deferred region has nothing to run.
	fp.dynarray.clear(regionScratch);
	return collectRegion(mod, subtree, regionScratch);
}


// ---------------------------------------------------------------------------
// Running one
// ---------------------------------------------------------------------------

/// The value an argument travels to the VM as.
///
/// A number is itself; a string is its bytes' address; a type, a block and a
/// field of an aggregate are all their own entity id, which is what makes
/// `mizu.doir`'s reflection instructions work on a plain register - each names
/// something in the store rather than holding a value, and the instruction
/// asks the store.
private ulong argumentValue(ref Module mod, EntityId e) @trusted {
	immutable type = resolveCached(mod, "type", 1, true);
	immutable blockType = resolveCached(mod, "block", 1, true);

	if (hasComponent!Number(mod, e))
		return cast(ulong) getComponent!Number(mod, e).value;
	if (hasComponent!ComptimeNumber(mod, e))
		return cast(ulong) getComponent!ComptimeNumber(mod, e).value;
	if (hasComponent!DString(mod, e))
		return cast(ulong) cast(size_t) getComponent!DString(mod, e).value.view.ptr;
	if (hasComponent!ComptimeString(mod, e))
		return cast(ulong) cast(size_t) getComponent!ComptimeString(mod, e).value.view.ptr;
	// `TypeDefinition` as well as `TypeOf == type`: an instruction that builds
	// a type leaves the definition and no declared type.
	if (hasComponent!TypeDefinition(mod, e) || isAggregateField(mod, e)
		|| (hasComponent!TypeOf(mod, e)
			&& (getComponent!TypeOf(mod, e).related[0] == blockType
				|| getComponent!TypeOf(mod, e).related[0] == type)))
		return resolveAlias(mod, e);

	// Unreachable: `collectRegion` only completes when every argument is one of
	// the above or another call in the region, and a region is what gets here.
	panic("Comptime evaluation of call with non-comptime parameter");
	return 0;
}

/// The index of `e` in `region`, or `region.length` if it is not a member.
private size_t memberIndex(const(EntityId)[] region, EntityId e) {
	foreach (i, m; region) if (m == e) return i;
	return region.length;
}

/// Runs the region rooted at `subtree`: every call in it, in one Mizu program,
/// arguments before the calls that read them.
///
/// `mizuSchedule` is the schedule spliced source is lowered with - any libECRS
/// system, so the driver can hand over whatever it composed out of
/// `doir.systems`' walkers.
bool comptimeEvaluate(ref Module mod, EntityId subtree, SystemFunction mizuSchedule) @trusted {
	if (!hasComponent!Call(mod, subtree)) return true;
	if (alreadyFolded(mod, subtree)) return true;


	EntityId* region;
	scope(exit) fp.dynarray.free(region);
	if (!collectRegion(mod, subtree, region)) return true;

	immutable setModuleOp = instructionOf(mod,
		resolveCached(mod, "mizu.doir.set_module", 1, true));
	immutable attachOp = instructionOf(mod,
		resolveCached(mod, "mizu.doir.attach_comptime_number_i64", 1, true));
	// A module that early_include'd no backend has neither, and `evaluableCall`
	// has already declined on that - but it answers by *name*, and these two
	// are read out of a body. Decided before `fixedPointChanged` below:
	// standing down after announcing a change is a fixed point that never
	// settles.
	if (setModuleOp is null || attachOp is null) return true;

	// The root, which is the call the walk asked about. Read at build time by
	// whatever folds a `compiler.current_entity` reference, and not by the
	// program: an instruction reads the entity it is acting for out of
	// `currentEntityRegister`, which is set once per call below.
	immutable compilerCurrentEntity = resolveCached(mod, "compiler.current_entity", 1, true);
	getComponent!Number(mod, compilerCurrentEntity).value = subtree;

	fixedPointChanged() = true;

	ComptimeProgram program;
	scope(exit) free(program);
	begin(program, mod, setModuleOp);

	auto members = fp.dynarray.slice(region);
	Reg[maximumRegionSize] results;
	foreach (i, call; members) {
		immutable op = instructionOf(mod,
			resolveAlias(mod, getComponent!Call(mod, call).related[0]));

		Reg[2] operands = [0, 0];
		if (hasComponent!FunctionInputs(mod, call)) {
			auto inputs = &getComponent!FunctionInputs(mod, call);
			foreach (j; 0 .. daLength(inputs.related)) {
				if (j >= operands.length) break;
				immutable a = resolveAlias(mod, inputs.related[j]);
				// An argument the region computes is already in a register.
				// This is the whole point of a region: the value never goes
				// out to the store and back, so the call above does not have
				// to wait for a later round of the fixpoint to read it.
				immutable member = memberIndex(members[0 .. i], a);
				operands[j] = member < i
					? results[member]
					: loadOperand(program, j, argumentValue(mod, a));
			}
		}

		setCurrentEntity(program, call);
		results[i] = callWith(program, op, operands[0], operands[1]);
		// TODO: Store back string
		callDiscarding(program, attachOp, currentEntityRegister(), results[i]);
	}
	end(program);

	run(program);

	// An instruction may have spliced source into the call it replaced rather
	// than handing back a number - `mizu.doir.execute` is the whole reason this
	// pass runs inside the lowering schedule at all.
	foreach (call; members)
		if (hasComponent!Block(mod, call) && !lowerSpliced(mod, call, mizuSchedule))
			return false;

	return true;
}

/// Lowers source an instruction spliced into `call`.
///
/// What it spliced is a copy of what the program *wrote*, so it has had none
/// of the lowering the code around it has: no registers, no materialized
/// immediates, its own calls still calls. Lower it the same way the module
/// around it is (C-Lower).
///
/// Including whatever compile time work it contains. There used to be a flag
/// suppressing that - `evaluating`, back when building the program for one call
/// meant running this very schedule over a synthesized block, so re-entering
/// was infinite by construction (see `doir.comptime.program`). Building the
/// program directly ended the recursion but the flag outlived it, and what it
/// then did was tell the inliner this pass did not want the dispatch inside a
/// `while` body - so the inliner took it, and `std.while` was the only
/// construct in the repository whose dispatch came out as machine code.
///
/// What bounds the nesting now is the source: each splice is finite and
/// spliced once, so the depth is the program's own nesting of dispatches.
private bool lowerSpliced(ref Module mod, EntityId call, SystemFunction mizuSchedule) @trusted {
	immutable splicedBackup = newRoot;
	newRoot = call;
	// Every id here - `call`, `splicedBackup`, and every id the walk that
	// reached this region is holding - is an id in the module, and a sort
	// renumbers all of them. See `canon.sort.sortSuspended`.
	//
	// Saved and put back rather than cleared, because this nests: a splice
	// holds compile time work of its own, and the inner lowering clearing the
	// flag let a `sort` run inside the outer one and renumber every id it was
	// holding, `newRoot` included.
	immutable suspendedBackup = sortSuspended;
	sortSuspended = true;
	// The walk starts inside the module rather than at its root, so it never
	// meets the `begin_register_allocation` call that would otherwise turn
	// allocation on - and spliced code needs registers exactly like the code
	// around it.
	immutable wasAllocating = beginRegisterAllocation();
	immutable ok = mizuSchedule(mod.ctx);
	endRegisterAllocation(wasAllocating);
	sortSuspended = suspendedBackup;
	newRoot = splicedBackup;
	return ok;
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
	// The two questions are one question now. A chain used to fold innermost
	// first, one program per link, so when `opt.inlineFunctions` asked about
	// the outer link its argument was still an unfolded call and
	// `comptimeEvaluationPending` said no - and the inliner, which acts on the
	// answer irrevocably, replaced the link with the bytes of the instruction
	// that computes it. That cost `std.add`'s dispatch its comparison, and the
	// weaker `comptimeEvaluationClaims` that fixed it was a *prediction*, which
	// went wrong the other way: a call it claimed and the evaluator never
	// reached was neither inlined nor folded.
	//
	// A region runs the whole chain in one program, so the outer link is
	// runnable the moment the inner one is, and claiming it is a promise the
	// pass keeps.
	auto f = withMizu("claims.doir");
	scope(exit) freeModule(f.mod);

	auto block = BlockBuilder(f.root, &f.mod);
	immutable byte_ = resolveLookupName(f.mod, internIn(f.mod, "compiler.byte"), f.root);
	immutable n = pushNumber(block, internIn(f.mod, "n"), byte_, 1);

	EntityId[2] leaf = [n, n];
	immutable inner = pushComptimeAdd(f, leaf[]);
	assert(comptimeEvaluationPending(f.mod, inner));
	assert(comptimeEvaluationClaims(f.mod, inner));

	// The outer call runs too, although `inner` has no value yet: `inner` is
	// in its region, so the one program computes both and the result never
	// goes out to the store and back.
	EntityId[2] chained = [inner, inner];
	immutable outer = pushComptimeAdd(f, chained[]);
	assert(comptimeEvaluationClaims(f.mod, outer));
	assert(comptimeEvaluationPending(f.mod, outer));

	// Not every unfolded argument, though - this is where a region stops. A
	// `compiler.assembler.*` call is `opt.computeCompilerNamespace`'s to fold
	// and never the evaluator's, so it cannot join the region and the call
	// reading it has to be inlined rather than waited for. That is every
	// instruction encoder in `mizu.doir`, each of them reading a
	// `return_register`; standing down for one left every instruction two
	// bytes short of its operand.
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

unittest { // one program folds a whole chain, in one visit
	// What the region is for. `add(add(2, 3), add(2, 3))` is three calls and
	// two levels, and the old pass needed a round of the fixpoint per level:
	// the inner call folded, and only on the next round did the outer one have
	// a constant to read. Here the inner result stays in a register and the
	// outer call reads it, so one visit answers all three.
	auto f = withMizu("region.doir");
	scope(exit) freeModule(f.mod);

	auto block = BlockBuilder(f.root, &f.mod);
	immutable byte_ = resolveLookupName(f.mod, internIn(f.mod, "compiler.byte"), f.root);
	immutable two = pushNumber(block, internIn(f.mod, "two"), byte_, 2);
	immutable three = pushNumber(block, internIn(f.mod, "three"), byte_, 3);

	EntityId[2] leaves = [two, three];
	immutable inner = pushComptimeAdd(f, leaves[]);
	// Both readers are the *same* argument entity, so the region is a DAG and
	// the program must still run `inner` once - twice would be twice the
	// effect for an instruction that has one.
	EntityId[2] chained = [inner, inner];
	immutable outer = pushComptimeAdd(f, chained[]);

	assert(comptimeEvaluate(f.mod, outer, &moduleSystem!mizuSchedule));

	assert(hasComponent!ComptimeNumber(f.mod, inner));
	assert(getComponent!ComptimeNumber(f.mod, inner).value == 5);
	// 10, not 5: the outer call read the inner one's register rather than the
	// store, and neither call ran twice.
	assert(hasComponent!ComptimeNumber(f.mod, outer));
	assert(getComponent!ComptimeNumber(f.mod, outer).value == 10);

	assert(!diagnostics().hasErrors());
	diagnostics().clear();
}

unittest { // a region stops at an argument that is nobody's to fold
	// The region is what makes the inliner's question answerable, so the
	// boundary has to be exact: an argument the evaluator will not supply
	// leaves the whole chain unclaimed, however comptime it looks.
	auto f = withMizu("region_edge.doir");
	scope(exit) freeModule(f.mod);

	auto block = BlockBuilder(f.root, &f.mod);
	immutable registerType = resolveLookupName(f.mod,
		internIn(f.mod, "compiler.assembler.register"), f.root);
	immutable returnRegister = resolveLookupName(f.mod,
		internIn(f.mod, "compiler.assembler.return_register"), f.root);
	EntityId[1] typeArg = [resolveLookupName(f.mod, internIn(f.mod, "mizu.u64"), f.root)];
	immutable regret = pushCall(block, internIn(f.mod, "regret"), registerType,
		returnRegister, typeArg[]);
	getOrAddComponent!Flags(f.mod, regret).flags |= Flags.Comptime;

	EntityId[2] viaRegister = [regret, regret];
	immutable inner = pushComptimeAdd(f, viaRegister[]);
	EntityId[2] chained = [inner, inner];
	immutable outer = pushComptimeAdd(f, chained[]);

	// Neither link, and the outer one for the inner one's reason rather than
	// one of its own.
	assert(!comptimeEvaluationClaims(f.mod, inner));
	assert(!comptimeEvaluationClaims(f.mod, outer));

	// And asking does not fold anything: the inliner asks once per call in the
	// module, so the question has to be free of effects.
	assert(comptimeEvaluate(f.mod, outer, &moduleSystem!mizuSchedule));
	assert(!hasComponent!ComptimeNumber(f.mod, outer));

	assert(!diagnostics().hasErrors());
	diagnostics().clear();
}

unittest { // a region waiting on a parameter is claimed but not pending
	// The difference between "not mine" and "not yet". A function body is a
	// template and its dispatch is written against its parameters, so the
	// chain cannot run where it is declared - but the inliner reads the claim,
	// and answering no there let it replace the chain *in the declaration*
	// with the bytes of the instructions that compute it. Every copy taken
	// afterwards carried that, so whether `std.add`'s dispatch collapsed came
	// down to whether the inliner reached a call site before the declaration.
	auto f = withMizu("region_parameter.doir");
	scope(exit) freeModule(f.mod);

	auto block = BlockBuilder(f.root, &f.mod);
	immutable byte_ = resolveLookupName(f.mod, internIn(f.mod, "compiler.byte"), f.root);
	// A parameter *with* a value, so that nothing but `FunctionParameter`
	// stands between the region and running: that is the whole claim.
	immutable parameter = pushNumber(block, internIn(f.mod, "p"), byte_, 1);
	addComponent!FunctionParameter(f.mod, parameter);

	EntityId[2] viaParameter = [parameter, parameter];
	immutable inner = pushComptimeAdd(f, viaParameter[]);
	EntityId[2] chained = [inner, inner];
	immutable outer = pushComptimeAdd(f, chained[]);

	// Both claimed, so the inliner leaves the chain whole...
	assert(comptimeEvaluationClaims(f.mod, inner));
	assert(comptimeEvaluationClaims(f.mod, outer));
	// ...and neither runnable, so the evaluator does not pretend to have an
	// answer for a name no call site has bound.
	assert(!comptimeEvaluationPending(f.mod, inner));
	assert(!comptimeEvaluationPending(f.mod, outer));
	assert(comptimeEvaluate(f.mod, outer, &moduleSystem!mizuSchedule));
	assert(!hasComponent!ComptimeNumber(f.mod, outer));

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
