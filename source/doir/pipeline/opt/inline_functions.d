/// `opt.inlineFunctions`: replaces a call to an inline-marked function with a
/// copy of its body. Ported from opt/inline_functions.cpp.
module doir.pipeline.opt.inline_functions;

import core.stdc.stdio : snprintf;

import ecrs.storage : EntityId, invalidEntity;

static import fp.dynarray;
import fp.dynarray : daLength = length;

import doir.interface_;
import doir.module_;
import doir.string_helpers : InternedString;

@nogc nothrow:


bool inlineFunctions(ref Module mod, EntityId subtree) @trusted {
	if (!hasComponent!Call(mod, subtree)) return true;

	immutable functionDef = resolveAlias(mod, getComponent!Call(mod, subtree).related[0]);
	if (!hasComponent!TypeOf(mod, functionDef)) return true;
	immutable ft = getComponent!TypeOf(mod, functionDef).related[0];
	if (!(flagsSet(mod, ft, Flags.Inline) || flagsSet(mod, subtree, Flags.Inline)))
		return true;

	// There has to be a body to copy. A builtin (`compiler.emit` and friends)
	// is declared `Valueless` and carries no `Block`, so `inline` on one used
	// to walk straight into `associatedParameters` and assert. Leaving it as an
	// ordinary call is what happens to every non-`inline` builtin anyway.
	if (!hasComponent!Block(mod, functionDef)) return true;

	removeComponent!Call(mod, subtree);

	// Snapshot the arguments before the component goes away.
	EntityList inputs;
	scope(exit) inputs.free();
	{
		auto stored = &getComponent!FunctionInputs(mod, subtree);
		foreach (i; 0 .. daLength(stored.related))
			inputs.push(stored.related[i]);
	}
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
		getOrAddComponent!Flags(mod, subtree).flags = flags;
	}

	auto params = associatedParameters(mod, inputs.length, functionDef);
	scope(exit) params.free();

	addComponent!Block(mod, subtree);
	auto block = BlockBuilder(subtree, &mod);

	EntityMap paramReplacements;
	scope(exit) paramReplacements.free();
	foreach (i; 0 .. inputs.length) {
		InternedString name;
		if (hasComponent!Name(mod, params[i]))
			name = getComponent!Name(mod, params[i]).value;
		else {
			char[24] buffer;
			immutable n = snprintf(buffer.ptr, buffer.length, "a%zu", i);
			name = internIn(mod, buffer[0 .. n]);
		}
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
	EntityPairLiteral[2] returnSubs = [
		EntityPairLiteral(indicateReturn, indicateYield),
		EntityPairLiteral(returnRegister, yieldRegister),
	];
	substituteEntities(mod, subtree, returnSubs[], 1);

	return true;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest) {
	import doir.diagnostics : diagnostics;
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
