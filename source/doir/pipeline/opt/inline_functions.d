/// `opt.inlineFunctions`: replaces a call to an inline-marked function with a
/// copy of its body. Ported from opt/inline_functions.cpp.
module doir.pipeline.opt.inline_functions;


import ecrs.storage : EntityId, invalidEntity;

static import fp.dynarray;
import fp.dynarray : daLength = length;

import doir.interface_;
import doir.module_;
import doir.string_helpers : InternedString;
import doir.pipeline.opt.mizu.comptime_evaluate : comptimeEvaluationClaims;

@nogc nothrow:


bool inlineFunctions(ref Module mod, EntityId subtree) @trusted {
	if (!hasComponent!Call(mod, subtree)) return true;

	immutable functionDef = resolveAlias(mod, getComponent!Call(mod, subtree).related[0]);
	if (!hasComponent!TypeOf(mod, functionDef)) return true;

	// No ownership question about the *callee*. Inlining is an edit to the call
	// site, and the walk has already asked whether this schedule owns that - so
	// asking again about where the body happens to be declared answers a
	// question nobody posed, and answers it wrongly the moment two schedules are
	// in play: `mizu.doir` claims its own block, so a call in the module's root
	// to `mizu.find_label` was inlined by nobody at all. The site's schedule
	// owned the site but not the body; the backend's schedule owned the body but
	// never visits the site. A body is read here, not written, and reading
	// somebody else's declaration is what every call does.

	immutable ft = getComponent!TypeOf(mod, functionDef).related[0];
	if (!(flagsSet(mod, ft, Flags.Inline) || flagsSet(mod, subtree, Flags.Inline)))
		return true;

	// Not a call `opt.mizu.comptimeEvaluate` owns. Both passes are in the
	// lowering schedule and this one reaches a call first, so the ordering has
	// to be asked for rather than scheduled: inlining `mizu.doir.execute`
	// replaces the call with the bytes of the execute *instruction*, which in
	// the emitted program would mean editing the compiler's entity store at
	// runtime.
	//
	// `Claims` rather than `Pending`: the evaluator can only *run* a call whose
	// arguments are already folded, and at this point in the schedule nothing
	// has been folded at all - so asking whether it can run yet stood down for
	// the first link of a comptime chain and inlined every link after it. See
	// that function's own comment.
	if (comptimeEvaluationClaims(mod, subtree)) return true;

	// There has to be a body to copy. A builtin (`compiler.emit` and friends)
	// is declared `Valueless` and carries no `Block`, so `inline` on one used
	// to walk straight into `associatedParameters` and assert. Leaving it as an
	// ordinary call is what happens to every non-`inline` builtin anyway.
	if (!hasComponent!Block(mod, functionDef)) return true;

	removeComponent!Call(mod, subtree);

	// Snapshot the arguments before the component goes away.
	auto inputs = inputEntities(mod, subtree);
	scope(exit) fp.dynarray.free(inputs);
	removeComponent!FunctionInputs(mod, subtree);

	// Drop the flags that described the *call* now, before the body is copied
	// in - not afterwards. `subtree` is no longer a call, and for a recursive
	// function `functionDef`'s children include `subtree` itself, so
	// `copyExisting` below snapshots whatever state it is in: clearing the
	// flags late produced a copy that was a `Block` with no `Call` but still
	// carrying `Flags.Inline`, which `doir.verify` rejects outright.
	{
		ushort flags = 0;
		if (flagsSet(mod, subtree, Flags.Export)) flags |= Flags.Export;
		if (flagsSet(mod, subtree, Flags.Flatten)) flags |= Flags.Flatten;
		// Not a description of the call: it says this entity's own type is
		// still a hole, which replacing the call with a body does not answer.
		if (flagsSet(mod, subtree, Flags.TypeVariable)) flags |= Flags.TypeVariable;
		getOrAddComponent!Flags(mod, subtree).flags = flags;
	}

	auto params = associatedParameters(mod, daLength(inputs), functionDef);
	scope(exit) fp.dynarray.free(params);

	addComponent!Block(mod, subtree);
	getOrAddComponent!Flags(mod, subtree).flags |= Flags.Freestanding;
	auto block = BlockBuilder(subtree, &mod);

	EntityMap paramReplacements;
	scope(exit) paramReplacements.free();
	foreach (i; 0 .. daLength(inputs)) {
		InternedString name;
		if (hasComponent!Name(mod, params[i]))
			name = getComponent!Name(mod, params[i]).value;
		else name = defaultParameterName(mod, i);
		paramReplacements.set(params[i], pushAlias(block, name, inputs[i]));
	}

	auto source = BlockBuilder(functionDef, &mod);
	copyExisting(block, source, true);
	substituteEntities(mod, subtree, paramReplacements);

	immutable indicateReturn = resolveLookupName(mod, internIn(mod, "compiler.indicate_return"), 1);
	immutable indicateYield = resolveLookupName(mod, internIn(mod, "compiler.indicate_yield"), 1);
	immutable returnRegister = resolveLookupName(mod, internIn(mod, "compiler.assembler.return_register"), 1);
	immutable yieldRegister = resolveLookupName(mod, internIn(mod, "compiler.assembler.yield_register"), 1);
	// TODO: Does this fix recursive issues? TODO: Calls to return should become calls to yield
	immutable return_ = resolveLookupName(mod, internIn(mod, "compiler.return"), 1);
	immutable yield = resolveLookupName(mod, internIn(mod, "compiler.yield"), 1);
	EntityPairLiteral[3] returnSubs = [
		EntityPairLiteral(indicateReturn, indicateYield),
		EntityPairLiteral(returnRegister, yieldRegister),
		// `return v` becomes `yield v` for the same reason the marker does: a
		// body copied into a call site hands its value to that call, not out of
		// whatever function now contains it.
		EntityPairLiteral(return_, yield),
	];
	substituteEntities(mod, subtree, returnSubs[], 1);

	return true;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest) {
	import doir.diagnostics : diagnostics;
	import doir.systems : beginLoweringBlock, beginLoweringSchedule, endLoweringBlock, endLoweringSchedule, ownedByCurrentLowering;
	import tests.pipeline_helper;
}

unittest {
	// `inline` on a builtin. `compiler.emit` is declared `Valueless` and has no
	// `Block`, so there is no body to copy in; this used to assert inside
	// `associatedParameters` after the `Call` component had already been torn
	// off. Leaving it as an ordinary call is what every non-`inline` builtin
	// call already does, so it still emits its byte.
	auto r = compile(
		"%0 : compiler.byte = 0x48\n"
		~ "%1 : compiler.byte = inline compiler.emit(%0)\n");
	scope(exit) freeModule(r.mod);
	assert(r.ok);
	static immutable ubyte[1] expected = [0x48];
	assert(emits(r, expected[]));
	diagnostics().clear();
}

unittest {
	// A recursive function inlined into itself. `functionDef`'s children include
	// the very entity being rewritten, so `copyExisting` snapshots `subtree`
	// mid-rewrite; clearing the call's flags after that copy left a `Block` with
	// no `Call` still carrying `Flags.Inline`, which `doir.verify` panicked on
	// ("Invalid flags"). The recursion is bounded by how many times the schedule
	// runs the pass, so what matters here is that the IR stays valid.
	auto r = compile(
		"f : () -> compiler.byte = {\n"
		~ "\t_ : compiler.byte = inline f()\n"
		~ "}\n"
		~ "x : compiler.byte = inline f()\n");
	scope(exit) freeModule(r.mod);
	assert(r.ok);
	assert(find(r.mod, r.root, "x") != invalidEntity);
	diagnostics().clear();
}

unittest {
	// Ditto without `inline`: the call is vacuously comptime (it has no
	// arguments for `bubbleComptime` to reject), so `opt.mizu.comptimeEvaluate`
	// took it, assembled a program out of `mizu.*` names that resolve to
	// `invalidEntity` in a module that never included mizu.doir, and jumped the
	// VM at the resulting garbage.
	auto r = compile(
		"f : () -> compiler.byte = {\n"
		~ "\t_ : compiler.byte = f()\n"
		~ "}\n"
		~ "x : compiler.byte = f()\n");
	scope(exit) freeModule(r.mod);
	assert(r.ok);
	assert(find(r.mod, r.root, "x") != invalidEntity);
	diagnostics().clear();
}

unittest {
	// A parameter with no name of its own - `_`, which `pushCommon` attaches
	// no `Name` for - gets a generated `a<n>` so the alias standing in for it
	// inside the inlined body still has something to be called.
	auto f = makeModuleWithBuiltins();
	scope(exit) freeModule(f.mod);
	diagnostics().clear();

	auto block = BlockBuilder(f.root, &f.mod);
	immutable byte_ = resolveLookupName(f.mod, internIn(f.mod, "compiler.byte"), f.root);

	Lookup[1] inputs = [Lookup(byte_)];
	InternedString[1] names = [InternedString("_")];
	immutable ft = pushFunctionType(block, internIn(f.mod, "ft"), inputs[], Lookup(byte_), true, names[]);
	getOrAddComponent!Flags(f.mod, ft).flags |= Flags.Inline;

	auto fb = pushFunction(block, internIn(f.mod, "fn"), ft, true);
	pushNumber(fb.builder, internIn(f.mod, "inner"), byte_, 1);
	immutable functionDef = fb.builder.block;
	assert(!hasComponent!Name(f.mod, getComponent!Block(f.mod, functionDef).related[0]));

	immutable argument = pushNumber(block, internIn(f.mod, "arg"), byte_, 2);
	immutable call = pushCall(block, internIn(f.mod, "c"), byte_, functionDef, (&argument)[0 .. 1]);

	assert(inlineFunctions(f.mod, call));
	assert(!hasComponent!Call(f.mod, call));
	assert(hasComponent!Block(f.mod, call));
	// The generated name is what the substituted alias is called.
	assert(resolveLookupName(f.mod, internIn(f.mod, "a0"), call) != invalidEntity);
	assert(!diagnostics().hasErrors());
	diagnostics().clear();
}

unittest {
	// A block's schedule inlines the calls *written in it*, wherever the body it
	// copies was declared - and leaves alone the calls written elsewhere, even
	// to functions it declared itself.
	//
	// It used to be the other way round, keyed on where the body lives. That
	// reads well and does not survive a second schedule: `mizu.doir` claims its
	// own block, so a `mizu.*` call written in a module that nominated a
	// schedule of its own was inlined by nobody - the site's schedule owned the
	// site but not the body, and mizu's schedule owned the body but never visits
	// the site. Inlining puts a body where the call stands, so the call's block
	// is the one whose schedule decides; a body declared elsewhere is read, as
	// any declaration is read from wherever it lives.
	auto f = makeModuleWithBuiltins();
	scope(exit) freeModule(f.mod);
	diagnostics().clear();

	auto root = BlockBuilder(f.root, &f.mod);
	immutable byte_ = resolveLookupName(f.mod, internIn(f.mod, "compiler.byte"), f.root);

	Lookup[0] noInputs;
	immutable ft = pushFunctionType(root, internIn(f.mod, "ft"), noInputs[], Lookup(byte_), true);
	getOrAddComponent!Flags(f.mod, ft).flags |= Flags.Inline;

	// `outer` belongs to the root block, `inner` to the namespace below it.
	auto outerFn = pushFunction(root, internIn(f.mod, "outer"), ft, true);
	pushNumber(outerFn.builder, internIn(f.mod, "a"), byte_, 1);
	immutable outer = outerFn.builder.block;

	auto ns = pushNamespace(root, internIn(f.mod, "ns"));
	auto innerFn = pushFunction(ns, internIn(f.mod, "inner"), ft, true);
	pushNumber(innerFn.builder, internIn(f.mod, "b"), byte_, 2);
	immutable inner = innerFn.builder.block;

	EntityId[0] noArguments;
	immutable callsOuter = pushCall(ns, internIn(f.mod, "co"), byte_, outer, noArguments[]);
	immutable callsInner = pushCall(ns, internIn(f.mod, "ci"), byte_, inner, noArguments[]);
	// Written at the root, calling into `ns` - the case that swaps sides.
	immutable rootCallsInner = pushCall(root, internIn(f.mod, "rci"), byte_, inner, noArguments[]);

	// `ns` has to actually claim a schedule for any of this to apply: what the
	// filter compares is claims, and outside a lowering there is nothing to
	// compare. This is the claim `opt.runSchedule` would have made from a
	// `compiler.run_schedule` call in the block.
	auto claimed = internIn(f.mod, "depthFirst(inlineFunctions)");
	addComponent!ScheduleClaim(f.mod, ns.block).source = claimed;

	{
		const previousSchedule = beginLoweringSchedule(claimed.view);
		scope(exit) endLoweringSchedule(previousSchedule);
		immutable previousBlock = beginLoweringBlock(ns.block);
		scope(exit) endLoweringBlock(previousBlock);

		// Written inside it, body declared outside: inlined, because the site is
		// `ns`'s.
		assert(inlineFunctions(f.mod, callsOuter));
		assert(!hasComponent!Call(f.mod, callsOuter));
		assert(hasComponent!Block(f.mod, callsOuter));

		// Written inside it, body inside it: inlined as always.
		assert(inlineFunctions(f.mod, callsInner));
		assert(!hasComponent!Call(f.mod, callsInner));
		assert(hasComponent!Block(f.mod, callsInner));

		// Written at the root: not `ns`'s to touch, though `ns` declared the
		// body. Asked of the filter rather than of the pass, because the pass no
		// longer has an opinion - the walk is what declines to hand an entity
		// over, and these two calls are the two answers it gives.
		assert(ownedByCurrentLowering(f.mod, callsInner));
		assert(!ownedByCurrentLowering(f.mod, rootCallsInner));
	}

	// Outside any lowering everything is owned - the restriction is the
	// schedule's, not the pass's.
	assert(ownedByCurrentLowering(f.mod, rootCallsInner));
	assert(inlineFunctions(f.mod, rootCallsInner));
	assert(!hasComponent!Call(f.mod, rootCallsInner));

	assert(!diagnostics().hasErrors());
	diagnostics().clear();
}
