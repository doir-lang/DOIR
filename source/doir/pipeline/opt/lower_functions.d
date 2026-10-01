/// `opt.claimFunctionLabels` / `opt.lowerFunctionCalls`: emits the functions
/// that are still standing once lowering has settled, and turns calls and
/// returns into jumps between their labels.
///
/// New with the D port; the C++ had no runtime call at all - every function was
/// either inlined or folded, which is why `byte_emiter` skips a
/// `compiler.emit` inside a function body (`findFunctionInsideOf`): nothing
/// ever emitted one.
///
/// That skip is still there, and `opt.liftFunctionBodies` below is what makes
/// it harmless: by the time `byte_emiter` runs there is no body for it to skip,
/// only a block of top level code the jumps land in.
///
/// ---------------------------------------------------------------------------
/// How a call reaches the callee's prologue
/// ---------------------------------------------------------------------------
/// It does not look it up. A label reference in this compiler is an *entity*
/// reference: `opt.mizu.materializeLabels` hands each `mizu.label()` call an id
/// and writes it back as a `ComptimeNumber` on the call entity, and
/// `mizu.find_label` reads that number off whatever entity sits in its argument
/// slot. `test.doir` closes the loop by name, which makes it look like a naming
/// problem - it is not. The name is only how a human writes the reference;
/// `FunctionInputs.related[0]` is an `EntityId`.
///
/// So what a call site needs is the function -> label map, and the store is the
/// map: `FunctionLabels`, on the function, holding the entry and exit label
/// entities. R-Unqual never has to reach into the callee's body, which it could
/// not do anyway - it only walks outward.
///
/// ---------------------------------------------------------------------------
/// Why two passes
/// ---------------------------------------------------------------------------
/// A call can precede its callee, so no single walk can both claim a function's
/// labels and rewrite the calls to it - the first call it reached would find no
/// claim. `opt.runSchedule` / `opt.runRegisteredSchedules` split for the same
/// reason, and `pipeline/package.d` says so there: claiming and running are two
/// passes rather than one.
module doir.pipeline.opt.lower_functions;

import ecrs.storage : EntityId, invalidEntity;

static import fp.dynarray;
import fp.dynarray : daLength = length;

import doir.interface_;
import doir.module_;
import doir.string_helpers : InternedString;

import doir.pipeline.canon.sort : loweringThrowawayBlock, newRoot;

@nogc nothrow:


/// The flags that mean the call sites have already consumed this function, so
/// there is no body left to jump to.
///
/// `Inline` is what separates a function from an instruction encoder: every
/// function type in `mizu.doir` is `always_inline`, so a call through one is
/// replaced by the bytes it emits rather than becoming a jump.
private enum ushort consumedByCallSites =
	Flags.Inline | Flags.Flatten | Flags.Comptime | Flags.AlwaysComptime;

/// Whether `body_` is an instruction encoder rather than a function: empty, or
/// nothing but `compiler.emit`/`emit_bytes`/`indicate_return`/`indicate_yield`
/// over its own constants.
///
/// The three `always_` flags say a *call site* consumed the function, and these
/// are consumed by a pass instead - `mizu.load_immediate` and its three
/// siblings by `opt.mizu.materializeImmediates`, `mizu.label` by
/// `opt.mizu.materializeLabels`, and the three `*_op` bodies beside them are
/// the opcode halves those two splice in. Nothing in the store says so, because
/// no flag means "expanded by a pass": `load_immediate_t` and `immediate_op_t`
/// carry `never_monomorphize` and nothing else, and `label` and `label_op` are
/// written with anonymous function types that carry nothing at all.
///
/// Leaving them out is not an optimization. `mizu.label` has a body, so
/// claiming it splices a `mizu.label()` call into `mizu.label` itself, and the
/// compile does not terminate.
private bool bodyOnlyEmits(ref Module mod, EntityId body_) @trusted {
	immutable emit = resolveCached(mod, "compiler.emit", 1);
	immutable emitBytes = resolveCached(mod, "compiler.emit_bytes", 1);
	immutable indicateReturn = resolveCached(mod, "compiler.indicate_return", 1);
	immutable indicateYield = resolveCached(mod, "compiler.indicate_yield", 1);

	auto related = &getComponent!Block(mod, body_).related;
	foreach (i; 0 .. daLength(*related)) {
		immutable e = (*related)[i];
		if (!hasComponent!Call(mod, e)) continue;
		immutable callee = resolveAlias(mod, getComponent!Call(mod, e).related[0]);
		if (callee == emit || callee == emitBytes) continue;
		if (callee == indicateReturn || callee == indicateYield) continue;
		if (isAssemblerAnnotation(mod, callee)) continue;
		return false;
	}
	return true;
}

/// Whether `callee` is declared under `compiler.assembler` - a register
/// annotation the allocator spliced in rather than something the body does.
///
/// Without this the answer depends on whether registers have been allocated
/// yet: `pinRegisters` puts a `compiler.assembler.pin_register` beside every
/// value, so after the register round *every* body looks like it does more
/// than emit, `mizu.label_op` is claimed as a function, a prologue is spliced
/// into it, and `materializeLabels` then emits a `label_op()` call inside
/// `label_op` - which inlines into itself until memory runs out.
private bool isAssemblerAnnotation(ref Module mod, EntityId callee) @trusted {
	immutable assembler = resolveCached(mod, "compiler.assembler", 1);
	if (assembler == invalidEntity) return false;

	EntityId e = callee;
	while (hasComponent!Parent(mod, e)) {
		e = getComponent!Parent(mod, e).related[0];
		if (e == invalidEntity) return false;
		if (e == assembler) return true;
	}
	return false;
}

/// A function body that still has to be emitted: a block, a function type, and
/// no flag saying it was spent during lowering.
///
/// Public because `opt.assignTemporaries` has the same question earlier: the
/// values in a body nothing reaches cost no registers, and this is what
/// decides whether anything reaches one. Asking it there rather than guessing
/// keeps the two rounds of allocation from disagreeing with the pass that
/// settles it.
bool needsEmitting(ref Module mod, EntityId e) {
	if (!hasComponent!Block(mod, e)) return false;
	if (flagsSet(mod, e, Flags.Namespace | consumedByCallSites)) return false;
	if (!hasComponent!TypeOf(mod, e)) return false;

	immutable type = resolveTypeModifications(mod,
		resolveAlias(mod, getComponent!TypeOf(mod, e).related[0]));
	if (!hasComponent!FunctionReturnType(mod, type)) return false;
	if (flagsSet(mod, type, consumedByCallSites)) return false;
	if (bodyOnlyEmits(mod, e)) return false;
	return true;
}

/// Inserts a fresh entity into `block` at `index`, the way `pushCommon` does
/// at either end. Mid-block because a prologue goes after the parameter
/// declarations and an exit label before the teardown, and neither is an end.
private EntityId insertAt(ref Module mod, EntityId block, size_t index) @trusted {
	immutable out_ = addEntity(mod);
	addComponent!Parent(mod, out_).related[0] = block;
	auto related = &getComponent!Block(mod, block).related;
	if (index >= daLength(*related)) fp.dynarray.pushBack(*related, out_);
	else fp.dynarray.insert(*related, index, out_);
	return out_;
}

/// Where a body's own code starts: past the parameter declarations, which are
/// listed in the block but are not statements.
private size_t firstStatement(ref Module mod, EntityId body_) @trusted {
	auto related = &getComponent!Block(mod, body_).related;
	size_t i = 0;
	while (i < daLength(*related) && hasComponent!FunctionParameter(mod, (*related)[i]))
		++i;
	return i;
}

/// `mizu.label()`, as a call with the register type every other label in the
/// module carries.
private EntityId pushLabelCall(ref Module mod, EntityId at, EntityId label, EntityId register) {
	EntityId[0] noInputs;
	return attachCall(mod, at, register, label, noInputs[]);
}


// ---------------------------------------------------------------------------
// Pass one: claim
// ---------------------------------------------------------------------------

/// Gives every function that still needs emitting an entry and an exit label,
/// records the pair in `FunctionLabels`, and splices the frame setup and
/// teardown around its body.
///
/// The labels are created here rather than inside
/// `std.functions.impl.prologue`'s body because a body is inlined once per call
/// site and a label must not be: the pair has to exist, and be the same pair,
/// before any call site can be rewritten to jump to it.
bool claimFunctionLabels(ref Module mod, EntityId subtree) @trusted {
	// Only the program the author wrote, the way `sema.typeCheck` asks. The
	// comptime evaluator lowers each throwaway block it builds with this same
	// schedule, and such a block is hand pinned to registers 1, 2 and 3 - a
	// prologue spliced into it would both move the stack under the VM and
	// leave the module being edited from inside the walk over it.
	if (loweringThrowawayBlock()) return true;
	if (hasComponent!FunctionLabels(mod, subtree)) return true;
	if (!needsEmitting(mod, subtree)) return true;

	immutable label = resolveCached(mod, "mizu.label", 1);
	immutable register = resolveCached(mod, "compiler.assembler.register", 1);
	immutable prologue = resolveCached(mod, "std.functions.impl.prologue", 1);
	immutable epilogue = resolveCached(mod, "std.functions.impl.epilogue", 1);
	// A module that included no backend has none of these. `invalidEntity` is
	// 0 and so is an unresolvable name, hence the guard `materializeLabels`
	// and `materializeImmediates` both carry.
	if (label == invalidEntity || register == invalidEntity) return true;
	if (prologue == invalidEntity || epilogue == invalidEntity) return true;

	immutable at = firstStatement(mod, subtree);
	immutable entry = pushLabelCall(mod, insertAt(mod, subtree, at), label, register);
	immutable setup = insertAt(mod, subtree, at + 1);
	{
		EntityId[1] args = [subtree];
		attachCall(mod, setup, register, prologue, args[]);
		getOrAddComponent!Flags(mod, setup).flags |= Flags.Inline;
	}

	// The exit label goes *above* the teardown, so that a `return` jumping to
	// it runs the teardown rather than skipping it.
	immutable end = daLength(getComponent!Block(mod, subtree).related);
	immutable exit = pushLabelCall(mod, insertAt(mod, subtree, end), label, register);
	immutable teardown = insertAt(mod, subtree, end + 1);
	{
		EntityId[1] args = [subtree];
		attachCall(mod, teardown, register, epilogue, args[]);
		getOrAddComponent!Flags(mod, teardown).flags |= Flags.Inline;
	}

	auto labels = &addComponent!FunctionLabels(mod, subtree);
	labels.related[0] = entry;
	labels.related[1] = exit;
	return true;
}


// ---------------------------------------------------------------------------
// Pass two: use
// ---------------------------------------------------------------------------

/// The label a transfer to `function_` jumps to, or `invalidEntity` if pass one
/// did not claim it. `which` is a `FunctionLabels` slot: 0 the entry label, 1
/// the exit one.
private EntityId labelOf(ref Module mod, EntityId function_, size_t which) {
	if (!hasComponent!FunctionLabels(mod, function_)) return invalidEntity;
	return getComponent!FunctionLabels(mod, function_).related[which];
}

/// What a `compiler.return` hands back: its last argument, because
/// `sema.deduceTypes` splices the solution for a deduced `T` in ahead of the
/// value it was solved from. `opt.pinRegisters` reads it the same way.
private EntityId returnedValue(ref Module mod, EntityId call) @trusted {
	if (!hasComponent!FunctionInputs(mod, call)) return invalidEntity;
	auto args = &getComponent!FunctionInputs(mod, call);
	if (daLength(args.related) == 0) return invalidEntity;
	return args.related[daLength(args.related) - 1];
}

/// Rewrites a call to an emitted function into `std.functions.impl.call` on its
/// entry label, with one `std.functions.impl.pass_argument` per argument above
/// it, and a `compiler.return` inside one into `std.functions.impl.return` on
/// its exit label.
bool lowerFunctionCalls(ref Module mod, EntityId subtree) @trusted {
	if (loweringThrowawayBlock()) return true;
	if (!hasComponent!Call(mod, subtree)) return true;

	immutable callee = resolveAlias(mod, getComponent!Call(mod, subtree).related[0]);
	if (callee == invalidEntity) return true;

	immutable implCall = resolveCached(mod, "std.functions.impl.call", 1);
	immutable implReturn = resolveCached(mod, "std.functions.impl.return", 1);
	immutable return_ = resolveCached(mod, "compiler.return", 1);
	immutable yield = resolveCached(mod, "compiler.yield", 1);
	immutable register = resolveCached(mod, "compiler.assembler.register", 1);
	immutable pointerSized = resolveCached(mod, "compiler.pointer_sized", 1);
	if (implCall == invalidEntity || implReturn == invalidEntity) return true;

	// A `return` inside an emitted body: keep it, since it is what pins the
	// value to the body's register (`opt.pinRegisters`), and put the move into
	// the result register and the jump to the teardown after it.
	if (callee == return_) {
		immutable owner = findFunctionInsideOf(mod, subtree);
		if (owner == invalidEntity) return true;
		immutable exit = labelOf(mod, owner, 1);
		if (exit == invalidEntity) return true;

		// The value is `compiler.return`'s last argument, as `opt.pinRegisters`
		// reads it: `sema.deduceTypes` splices the solution for `T` in ahead of
		// the value it was solved from.
		immutable value = returnedValue(mod, subtree);
		if (value == invalidEntity) return true;

		// A `return` standing immediately above the exit label used to skip
		// the jump, since it would be a jump to the next instruction. That is
		// gone: `impl.return` is the move into the result register *and* the
		// jump, and the move is never redundant. A body whose last `return`
		// sits on the label pays one jump for it, which is an instruction
		// rather than a correctness problem - and the check only fired when the
		// two were actually adjacent, which earlier passes made uncommon.
		immutable parent = findParent(mod, subtree);
		immutable valueType = hasComponent!TypeOf(mod, value)
			? getComponent!TypeOf(mod, value).related[0] : register;

		EntityId[3] returnArgs = [valueType, value, exit];
		immutable e = insertAt(mod, parent, indexIn(mod, parent, subtree) + 1);
		attachCall(mod, e, register, implReturn, returnArgs[]);
		getOrAddComponent!Flags(mod, e).flags |= Flags.Inline;
		return true;
	}

	immutable entry = labelOf(mod, callee, 0);
	if (entry == invalidEntity) return true;

	// The call becomes a block holding the transfer, the way
	// `materializeLabels` turns a `label()` into the block that encodes it.
	//
	// `impl.call` is handed the callee and `subtree` as well as the entry
	// label, and that is the whole of the marshalling as far as this pass is
	// concerned. The arguments are on `subtree`, which keeps its
	// `FunctionInputs` for exactly that reason, and the parameters they bind
	// are on `callee`; `std.functions.impl.call` walks the two together with
	// `meta.argument_count` / `meta.argument` / `meta.parameter` (R-Args).
	// Neither list is one a callee could reach on its own - R-Unqual only
	// walks outward - so being given both entities is what makes the
	// convention statable in `standard.doir` rather than here.
	immutable type = getComponent!TypeOf(mod, subtree).related[0];
	removeComponent!TypeOf(mod, subtree);
	removeComponent!Call(mod, subtree);
	auto builder = attachSubblock(mod, subtree, type);
	{
		// The callee and the call go in as comptime NUMBERS holding their
		// entity ids, not as references to the entities themselves. C-Call
		// folds a call only when its arguments are compile time known, and
		// `meta.argument_count` has to fold - it is loop control for an unroll,
		// and an unroll whose bound is a register is not an unroll. The call
		// entity is a block of emitted code and so is not comptime and must
		// not be marked so; a number holding its id is both.
		//
		// `opt.mizu.materializeLabels` makes the same move for the entry label,
		// writing a `ComptimeNumber` onto it for `find_label` to read - which
		// is why `entry` can stay an entity here. It is also the catch:
		// `canon.sort` renumbers every entity, so an id baked into a `Number`
		// is only good until the next sort. Nothing sorts between here and the
		// register round, and anything added that does has to run before this.
		immutable functionId = pushNumber(builder, InternedString("_"), pointerSized, callee);
		immutable callId = pushNumber(builder, InternedString("_"), pointerSized, subtree);

		EntityId[3] args = [entry, functionId, callId];
		immutable c = pushCall(builder, InternedString("_"), register, implCall, args[]);
		getOrAddComponent!Flags(mod, c).flags |= Flags.Inline;

		// And then the only thing that says the call site's value is the one
		// the transfer produced. `impl.call` ends in a `return` that pins its
		// result to its own block's register (WF-Term), but the block it is
		// inlined into is a level below the call site, and nothing relates the
		// two: without this the result is moved out of `a0` into a temporary
		// nothing reads, and whatever happened to be in the call site's
		// register is what the next instruction encodes.
		//
		// `yield` rather than `return`, because the call site is a block and
		// blocks yield - the same substitution `opt.inlineFunctions` makes when
		// it copies a body into a call site.
		EntityId[2] yieldArgs = [type, c];
		pushCall(builder, InternedString("_"), type, yield, yieldArgs[]);
	}
	builder.end();
	return true;
}

/// `e`'s position in `block`'s child list, or its length if it is not listed.
private size_t indexIn(ref Module mod, EntityId block, EntityId e) @trusted {
	auto related = &getComponent!Block(mod, block).related;
	foreach (i; 0 .. daLength(*related))
		if ((*related)[i] == e) return i;
	return daLength(*related);
}


// ---------------------------------------------------------------------------
// Pass zero: get the bodies out of the instruction stream
// ---------------------------------------------------------------------------

/// Whether `e` is a declaration rather than an instruction: a type (a function
/// type is one), a namespace, or a function definition.
///
/// A quoted block and a subblock an earlier pass expanded a call into both have
/// a `Block` and are neither - their `TypeOf` is `block` or a register type, not
/// a function type - which is what keeps this from sinking the very code it is
/// making room for.
private bool isDeclaration(ref Module mod, EntityId e) {
	if (hasComponent!TypeDefinition(mod, e)) return true;
	if (flagsSet(mod, e, Flags.Namespace)) return true;
	if (!hasComponent!Block(mod, e)) return false;
	if (!hasComponent!TypeOf(mod, e)) return false;

	immutable type = resolveTypeModifications(mod,
		resolveAlias(mod, getComponent!TypeOf(mod, e).related[0]));
	return hasComponent!FunctionReturnType(mod, type);
}

/// `opt.sinkDeclarations`: moves every type, function and namespace declaration
/// in the global scope below the instructions there.
///
/// An emitted function body is bytes in the instruction stream like any other,
/// so where its declaration sits in the block is where the machine walks into
/// it. Turning a call into a jump is only half of what makes a function a
/// function; the other half is that the program must not reach the body except
/// through that jump, and at module scope the only thing standing between the
/// top level code and a body declared in the middle of it is luck.
///
/// So the declarations go last, after the top level code and whatever
/// terminator it ends with. A module whose top level does not end in one still
/// falls into the first body, which is WF-Term's business rather than this
/// pass's.
///
/// Only the global scope. A declaration inside a body is that body's to order,
/// and a nested function is reached through its own label the same way.
///
/// Ahead of `claimFunctionLabels`, and followed by a `sort`: this leaves a
/// block whose child order no longer matches the post-order ids `canon.sort`
/// gave it, which is the invariant the walks after it read. Nothing holds a
/// label id yet at this point, so the renumbering costs nothing - which is
/// exactly why it goes here rather than after the labels exist.
bool sinkDeclarations(ref Module mod, EntityId root = currentCanonicalizeRoot) @trusted {
	if (loweringThrowawayBlock()) return true;
	immutable block = root == currentCanonicalizeRoot ? newRoot : root;
	if (!hasComponent!Block(mod, block)) return true;

	auto related = &getComponent!Block(mod, block).related;

	// Nothing to do unless some instruction actually follows some declaration.
	bool sawDeclaration = false;
	bool outOfOrder = false;
	foreach (i; 0 .. daLength(*related)) {
		if (isDeclaration(mod, (*related)[i])) sawDeclaration = true;
		else if (sawDeclaration) { outOfOrder = true; break; }
	}
	if (!outOfOrder) return true;

	EntityId* code = null;
	scope(exit) fp.dynarray.free(code);
	EntityId* declarations = null;
	scope(exit) fp.dynarray.free(declarations);

	// Stable within each group: two labels, or two bodies, keep the order the
	// author wrote them in.
	foreach (i; 0 .. daLength(*related)) {
		immutable e = (*related)[i];
		if (isDeclaration(mod, e)) fp.dynarray.pushBack(declarations, e);
		else fp.dynarray.pushBack(code, e);
	}

	fp.dynarray.clear(*related);
	foreach (i; 0 .. daLength(code)) fp.dynarray.pushBack(*related, code[i]);
	foreach (i; 0 .. daLength(declarations)) fp.dynarray.pushBack(*related, declarations[i]);
	return true;
}


// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
//
// These drive `doir.pipeline` over real source rather than calling the
// visitors, because what is being tested is the agreement between three passes
// and the schedule that orders them: a function that is not claimed until
// after its call site has been rewritten produces exactly the same store as
// one that was never claimed at all, and only a real compile tells them apart.

version (unittest) {
	import doir.diagnostics;
	import tests.pipeline_helper : compile, find, PipelineResult;

	/// One non-inline function and a call to it - the shape `test_call.doir`
	/// is - on top of the repository's own `standard.mizu.doir`, which is what
	/// supplies `std.functions.impl.*` and the schedule that runs these passes.
	///
	/// One `enum` rather than a prelude a helper prepends: concatenating a
	/// runtime string is a GC append, and `-betterC` drops the `@nogc` check
	/// that would have said so (it links instead as a missing symbol).
	private enum callSource =
		"path : compiler.byte_pointer = \"./standard.mizu.doir\"\n"
		~ "_ : compiler.byte = early_include(path)\n"
		~ "_ : compiler.assembler.register = compiler.assembler.begin_register_allocation()\n"
		~ "u64 : alias = mizu.u64\n"
		~ "add_one_t : type = (a : u64) -> u64\n"
		~ "add_one : add_one_t = {\n"
		~ "\tone : u64 = 1\n"
		~ "\t_ : u64 = mizu.load_immediate(u64, one)\n"
		~ "\tsum : u64 = std.add(a, one)\n"
		~ "\t_ : _ = std.return(sum)\n"
		~ "}\n"
		~ "x : u64 = 5\n"
		~ "_ : u64 = mizu.load_immediate(u64, x)\n"
		~ "y : u64 = add_one(x)\n"
		~ "_ : _ = std.halt()\n";

	/// Two `return`s in one body, which is what makes `impl.return` do
	/// anything: with a single one standing last, the jump to the exit label
	/// would be a jump to the next instruction and is skipped.
	private enum twoExitSource =
		"path : compiler.byte_pointer = \"./standard.mizu.doir\"\n"
		~ "_ : compiler.byte = early_include(path)\n"
		~ "_ : compiler.assembler.register = compiler.assembler.begin_register_allocation()\n"
		~ "u64 : alias = mizu.u64\n"
		~ "two_exits_t : type = (a : u64) -> u64\n"
		~ "two_exits : two_exits_t = {\n"
		~ "\tone : u64 = 1\n"
		~ "\t_ : u64 = mizu.load_immediate(u64, one)\n"
		~ "\t_ : _ = std.return(one)\n"
		~ "\ttwo : u64 = 2\n"
		~ "\t_ : u64 = mizu.load_immediate(u64, two)\n"
		~ "\t_ : _ = std.return(two)\n"
		~ "}\n"
		~ "x : u64 = 5\n"
		~ "_ : u64 = mizu.load_immediate(u64, x)\n"
		~ "y : u64 = two_exits(x)\n"
		~ "_ : _ = std.halt()\n";

	private PipelineResult withStandard() {
		return compile(callSource, "lower_functions.doir");
	}
}

unittest { // a surviving function gets two labels, and they are distinct
	auto r = withStandard();
	scope(exit) freeModule(r.mod);
	assert(r.ok);

	immutable add = find(r.mod, newRoot, "add_one");
	assert(add != invalidEntity);
	assert(hasComponent!FunctionLabels(r.mod, add));

	auto labels = &getComponent!FunctionLabels(r.mod, add);
	immutable entry = labels.related[0];
	immutable exit = labels.related[1];
	assert(entry != invalidEntity && exit != invalidEntity);
	// Two labels, not one reused: a `return` jumping to the entry would loop.
	assert(entry != exit);

	// `opt.mizu.materializeLabels` ran after the claim, so each carries the id
	// `mizu.find_label` searches for - which is the whole reason the pair is
	// created before the calls are rewritten rather than during.
	assert(hasComponent!ComptimeNumber(r.mod, entry));
	assert(hasComponent!ComptimeNumber(r.mod, exit));
	assert(getComponent!ComptimeNumber(r.mod, entry).value
		!= getComponent!ComptimeNumber(r.mod, exit).value);
	diagnostics().clear();
}

unittest { // the prologue runs first and the teardown last, after the sort
	auto r = withStandard();
	scope(exit) freeModule(r.mod);
	assert(r.ok);

	immutable add = find(r.mod, newRoot, "add_one");
	auto labels = &getComponent!FunctionLabels(r.mod, add);

	// Positions, not just membership. `canon.sort` used to order a body's
	// non-parameter children by entity id, and everything spliced in is created
	// after what it is spliced around - so all of it sorted to the end of the
	// body, which for a prologue means it never runs. A test that only asked
	// whether the labels were *in* the body passed in exactly that state.
	//
	// The labels are what is checked, rather than the frame setup either side
	// of them: `opt.inlineFunctions` runs after this pass and replaces a call
	// to `impl.prologue` with its body in place, so by the end of the schedule
	// there is no call left to find. The setup is spliced directly against its
	// label and the sort is stable, so a label in the right place is a setup in
	// the right place.
	immutable body_ = liftedBodyOf(r.mod, add);
	immutable one = find(r.mod, body_, "one");
	assert(one != invalidEntity);

	auto related = &getComponent!Block(r.mod, body_).related;
	immutable count = daLength(*related);
	size_t entryAt = count, exitAt = count, oneAt = count, lastParam = 0;
	foreach (i; 0 .. count) {
		immutable e = (*related)[i];
		if (hasComponent!FunctionParameter(r.mod, e)) lastParam = i;
		if (e == labels.related[0]) entryAt = i;
		if (e == labels.related[1]) exitAt = i;
		if (e == one) oneAt = i;
	}
	assert(entryAt != count && exitAt != count && oneAt != count);

	// The entry label is the first thing past the parameters, and the body
	// comes after it.
	assert(entryAt == lastParam + 1);
	assert(entryAt < oneAt);
	// The exit label is below the body, with the teardown below it - below, so
	// a `return` jumping to the label still runs it. Not the second to last
	// child: `opt.pinRegisters` leaves a constant and a `pin_register` after
	// each of them, neither of which emits.
	assert(oneAt < exitAt);
	assert(exitAt < count - 1);
	diagnostics().clear();
}

unittest { // the call site holds the callee's entry label, which is the gap
	auto r = withStandard();
	scope(exit) freeModule(r.mod);
	assert(r.ok);

	immutable add = find(r.mod, newRoot, "add_one");
	immutable entry = getComponent!FunctionLabels(r.mod, add).related[0];

	// `y` was a call; `lowerFunctionCalls` turned it into the block holding the
	// transfer, so it is no longer one.
	immutable y = find(r.mod, newRoot, "y");
	assert(y != invalidEntity);
	assert(!hasComponent!Call(r.mod, y));
	assert(hasComponent!Block(r.mod, y));

	// Somewhere under it, the entry label's id reaches an argument slot. That
	// is the answer to "how does a call find the prologue's label": not by
	// name - the label is inside a body R-Unqual cannot see into - but as an
	// entity the store handed over.
	assert(subtreeNames(r.mod, y, entry));
	diagnostics().clear();
}

version (unittest)
/// Whether any call under `subtree` has `target` among its arguments.
private bool subtreeNames(ref Module mod, EntityId subtree, EntityId target) @trusted {
	if (hasComponent!FunctionInputs(mod, subtree)) {
		auto inputs = &getComponent!FunctionInputs(mod, subtree);
		foreach (i; 0 .. daLength(inputs.related))
			if (resolveAlias(mod, inputs.related[i]) == target) return true;
	}
	if (!hasComponent!Block(mod, subtree)) return false;
	auto related = &getComponent!Block(mod, subtree).related;
	foreach (i; 0 .. daLength(*related))
		if (subtreeNames(mod, (*related)[i], target)) return true;
	return false;
}

unittest { // a return that is not the last statement jumps to the exit label
	auto r = compile(twoExitSource, "lower_functions.doir");
	scope(exit) freeModule(r.mod);
	assert(r.ok);

	immutable fn = find(r.mod, newRoot, "two_exits");
	assert(fn != invalidEntity);
	assert(hasComponent!FunctionLabels(r.mod, fn));
	immutable exit = getComponent!FunctionLabels(r.mod, fn).related[1];

	// Somewhere strictly above the exit label, something names it: the jump
	// `impl.return` became. Without it the first `return` pins its value and
	// then falls through into the second half of the body.
	auto related = &getComponent!Block(r.mod, liftedBodyOf(r.mod, fn)).related;
	size_t exitAt = daLength(*related);
	foreach (i; 0 .. daLength(*related))
		if ((*related)[i] == exit) exitAt = i;
	assert(exitAt != daLength(*related));

	bool jumps = false;
	foreach (i; 0 .. exitAt)
		if (subtreeNames(r.mod, (*related)[i], exit)) { jumps = true; break; }
	assert(jumps);
	diagnostics().clear();
}

unittest { // an inline function is not given labels: its call sites consumed it
	auto r = withStandard();
	scope(exit) freeModule(r.mod);
	assert(r.ok);

	// `std.if` is `always_inline`, and every `mizu.*` instruction type is too.
	immutable if_ = find(r.mod, newRoot, "std.if");
	assert(if_ != invalidEntity);
	assert(!hasComponent!FunctionLabels(r.mod, if_));

	// `mizu.label` is neither inline nor comptime, and has a body - so only
	// `bodyOnlyEmits` keeps it out. Claiming it would splice a `mizu.label()`
	// call into `mizu.label` itself and the compile would not terminate.
	immutable label = find(r.mod, newRoot, "mizu.label");
	assert(label != invalidEntity);
	assert(!hasComponent!FunctionLabels(r.mod, label));
	diagnostics().clear();
}

unittest { // declarations sink below the code, so nothing falls into a body
	auto r = withStandard();
	scope(exit) freeModule(r.mod);
	assert(r.ok);

	immutable add = find(r.mod, newRoot, "add_one");
	// The lifted body rather than `add_one` itself: the declaration no longer
	// holds anything, and what must stay out of the way is the code.
	immutable body_ = liftedBodyOf(r.mod, add);
	auto related = &getComponent!Block(r.mod, newRoot).related;

	size_t bodyAt = daLength(*related);
	size_t lastCode = 0;
	foreach (i; 0 .. daLength(*related)) {
		immutable e = (*related)[i];
		if (e == body_) bodyAt = i;
		else if (!isDeclaration(r.mod, e)) lastCode = i;
	}
	assert(bodyAt != daLength(*related));
	// Every instruction runs before the function body is reached.
	assert(bodyAt > lastCode);
	diagnostics().clear();
}


// ---------------------------------------------------------------------------
// Pass three: get the body out of the function
// ---------------------------------------------------------------------------

/// `opt.liftFunctionBodies`: moves an emitted function's body out of the
/// function and into the global scope, labels and all.
///
/// A function body is a *source* structure. Once lowering has settled there is
/// no such thing in the emitted program - there is a label, some instructions,
/// and a jump back - and leaving the code nested inside the declaration is
/// what every guard downstream then has to work around. Three of them ask
/// `findFunctionInsideOf` and mean "is this inside a body nothing jumps to":
/// `byte_emiter.emitCall`, `computeShiftRight` and `computeTruncateToByte`.
/// `compiler.assembler.register_for` is the same question again - it answers
/// nothing for a parameter of a function nothing inlined, because nothing
/// allocated one.
///
/// Lifting makes all four answers honest instead of special-cased. The
/// statements end up at module scope, where registers are allocated and
/// instruction encoders fold the way they always have, and `findFunctionInsideOf`
/// tells the truth: they are not inside a function any more.
///
/// After `lowerFunctionCalls`, which finds a `return`'s owner by walking up to
/// the enclosing function - there would be none to find afterwards.
bool liftFunctionBodies(ref Module mod, EntityId root = currentCanonicalizeRoot) @trusted {
	if (loweringThrowawayBlock()) return true;
	immutable global = root == currentCanonicalizeRoot ? newRoot : root;
	if (!hasComponent!Block(mod, global)) return true;

	immutable register = resolveCached(mod, "compiler.assembler.register", 1);

	// `compiler.return` says which register a *function* hands back, and this
	// body is a block now, so it yields - exactly the rewrite
	// `opt.inlineFunctions` makes for the same reason when it copies a body
	// into a call site. Depth one, because a function nested inside this one
	// still returns.
	EntityPairLiteral[3] returnSubs = [
		EntityPairLiteral(resolveCached(mod, "compiler.indicate_return", 1),
			resolveCached(mod, "compiler.indicate_yield", 1)),
		EntityPairLiteral(resolveCached(mod, "compiler.assembler.return_register", 1),
			resolveCached(mod, "compiler.assembler.yield_register", 1)),
		EntityPairLiteral(resolveCached(mod, "compiler.return", 1),
			resolveCached(mod, "compiler.yield", 1)),
	];

	immutable count = entityCount(mod);
	foreach (e; 0 .. count) {
		immutable f = cast(EntityId) e;
		if (f == global) continue;
		if (!entityExists(mod, f)) continue;
		if (!hasComponent!FunctionLabels(mod, f)) continue;
		// Already lifted: nothing to move, and moving twice would empty it.
		if (!hasComponent!Block(mod, f)) continue;

		// The body yields what the function returned.
		immutable type = hasComponent!FunctionReturnType(mod, f)
			? getComponent!FunctionReturnType(mod, f).related[0]
			: register;

		// Appended, so every lifted body lands below the top level code and
		// the terminator that keeps execution from walking into it -
		// `opt.sinkDeclarations` having already put the declarations there.
		auto dest = attachSubblock(mod, pushCommon(mod, global, InternedString("_")), type);
		auto src = BlockBuilder(f, &mod);
		moveExisting(dest, src);

		// What is left is a function declared and not defined, which
		// `verify.structure` accepts - and which is the truth: the definition
		// is now a block of its own, reached through `FunctionLabels`.
		removeComponent!Block(mod, f);
		getOrAddComponent!Flags(mod, f).flags |= Flags.Valueless;

		substituteEntities(mod, dest.block, returnSubs[], 1);
	}
	return true;
}
