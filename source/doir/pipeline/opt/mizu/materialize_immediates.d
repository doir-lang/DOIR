/// `opt.mizu.materializeImmediates`: expands a `mizu.load_immediate` call
/// into the byte sequence that encodes the instruction. Ported from
/// opt/mizu/materialize_immediates.hpp.
module doir.pipeline.opt.mizu.materialize_immediates;

import core.stdc.stdio : snprintf;

import ecrs.storage : EntityId, invalidEntity;

static import fp.dynarray;
import fp.dynarray : daLength = length;

import doir.interface_;
import doir.module_;
import doir.diagnostics;
import doir.string_helpers : InternedString;

@nogc nothrow:


bool materializeImmediates(ref Module mod, EntityId subtree) @trusted {
	if (!hasComponent!Call(mod, subtree)) return true;

	immutable u64 = resolveCached(mod, "mizu.u64", 1);
	immutable byteType = resolveCached(mod, "compiler.byte", 1);
	immutable emit = resolveCached(mod, "compiler.emit", 1);
	immutable indicateYield = resolveCached(mod, "compiler.indicate_yield", 1);
	immutable loadImmediate = resolveCached(mod, "mizu.load_immediate", 1);
	immutable loadImmediateOp = resolveCached(mod, "mizu.load_immediate_op", 1);
	immutable loadUpperImmediate = resolveCached(mod, "mizu.load_upper_immediate", 1);
	immutable loadUpperImmediateOp = resolveCached(mod, "mizu.load_upper_immediate_op", 1);

	immutable function_ = resolveAlias(mod, getComponent!Call(mod, subtree).related[0]);
	// `invalidEntity` is 0, and it is what both an unresolved callee and an
	// unresolvable `resolveCached` name come back as - so "neither resolved"
	// compared *equal* here. A module that never included mizu.doir (so every
	// `mizu.*` above is 0) and holds a call whose target is 0 was therefore
	// treated as a `load_immediate`, and reported "load_immediate expects two
	// inputs" against a synthesized entity, which aborts in
	// `findSourceLocation`. An unresolved callee is not any of these.
	if (function_ == invalidEntity) return true;
	if (!(function_ == loadImmediate || function_ == loadUpperImmediate)) return true;

	if (!hasComponent!FunctionInputs(mod, subtree)) {
		expectsXInputs(mod, subtree, "load_immediate", "two");
		return false;
	}

	auto inputs = resolvedInputs(mod, subtree);
	scope(exit) fp.dynarray.free(inputs);
	if (daLength(inputs) != 2) {
		expectsXInputs(mod, subtree, "load_immediate", "two");
		return false;
	}

	auto constant = comptimeNumber(mod, inputs[1]);
	if (constant.isNull) {
		// TODO: It would probably be good to relax this constraint in the future
		parameterError(mod, subtree, "load_immediate", 0, " must evaluate to a numeric constant");
		return false;
	}

	immutable target = inputs[1];
	immutable uint value = cast(uint) constant.get;

	immutable type = getComponent!TypeOf(mod, subtree).related[0];
	removeComponent!TypeOf(mod, subtree);
	removeComponent!Call(mod, subtree);
	auto builder = attachSubblock(mod, subtree, type);
	{
		EntityId[1] opInputs = [u64];
		immutable c = function_ == loadImmediate
			? pushCall(builder, InternedString("_"), u64, loadImmediateOp, opInputs[])
			: pushCall(builder, InternedString("_"), u64, loadUpperImmediateOp, opInputs[]);
		getOrAddComponent!Flags(mod, c).flags = Flags.Inline;

		// TODO: Some sort of actual register allocation logic would be nice
		if (!hasComponent!AssignedRegister(mod, target)) {
			noAssociatedRegister(mod, subtree, target);
			return false;
		}
		immutable r = getComponent!AssignedRegister(mod, target).reg;
		getOrAddComponent!AssignedRegister(mod, subtree).reg = r;

		immutable ubyte low = cast(ubyte)(r & 0xFF);
		EntityId[1] emitInputs;
		emitInputs[0] = pushNumber(builder, internIn(mod, "low"), byteType, low);
		pushCall(builder, InternedString("_"), byteType, emit, emitInputs[]);

		immutable ubyte high = cast(ubyte)((r >> 8) & 0xFF);
		emitInputs[0] = pushNumber(builder, internIn(mod, "high"), byteType, high);
		pushCall(builder, InternedString("_"), byteType, emit, emitInputs[]);

		auto bytes = (cast(const(ubyte)*) &value)[0 .. uint.sizeof];
		foreach (i; 0 .. bytes.length) {
			char[24] buffer;
			immutable n = snprintf(buffer.ptr, buffer.length, "%%%zu", i);
			emitInputs[0] = pushNumber(builder, internIn(mod, buffer[0 .. n]), byteType, cast(int) bytes[i]);
			pushCall(builder, InternedString("_"), byteType, emit, emitInputs[]);
		}

		emitInputs[0] = pushNumber(builder, internIn(mod, "zero"), byteType, 0);
		foreach (_; 0 .. 2) // Need to fill in another uint16_t
			pushCall(builder, InternedString("_"), byteType, emit, emitInputs[]);

		EntityId[1] yieldInputs = [u64];
		pushCall(builder, InternedString("_"), u64, indicateYield, yieldInputs[]);
	}
	builder.end();
	return true;
}


// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
//
// The expansion itself runs for every `mizu.load_immediate` in a real
// program (see `doir.pipeline`'s end-to-end tests). What is left here is the
// malformed calls, which `sema.functionArity` rejects long before this pass
// in a real compile - so they are built directly, in a module that has the
// mizu backend loaded so `mizu.load_immediate` resolves at all.

version (unittest) {
	static import fp.dynarray;

	import tests.pipeline_helper : makeModuleWithBuiltins, PipelineResult, withMizu;


	/// `mizu.load_immediate(args...)` pushed into the fixture's root block.
	private EntityId pushLoadImmediate(ref PipelineResult f, const(EntityId)[] args) {
		auto block = BlockBuilder(f.root, &f.mod);
		immutable u64 = resolveLookupName(f.mod, internIn(f.mod, "mizu.u64"), f.root);
		immutable loadImmediate = resolveLookupName(f.mod,
			internIn(f.mod, "mizu.load_immediate"), f.root);
		assert(loadImmediate != invalidEntity);
		return pushCall(block, InternedString("_"), u64, loadImmediate, args);
	}
}

unittest { // a well-formed call is expanded into the bytes that encode it
	auto f = withMizu("immediates.doir");
	scope(exit) freeModule(f.mod);

	auto block = BlockBuilder(f.root, &f.mod);
	immutable u64 = resolveLookupName(f.mod, internIn(f.mod, "mizu.u64"), f.root);
	immutable value = pushNumber(block, internIn(f.mod, "v"), u64, 1234);
	getOrAddComponent!AssignedRegister(f.mod, value).reg = 5;

	EntityId[2] args = [u64, value];
	immutable call = pushLoadImmediate(f, args[]);

	assert(materializeImmediates(f.mod, call));
	assert(!hasComponent!Call(f.mod, call));
	assert(hasComponent!Block(f.mod, call));
	assert(getComponent!AssignedRegister(f.mod, call).reg == 5);
	assert(!diagnostics().hasErrors());
	diagnostics().clear();
}

unittest { // a value the compiler only worked out is expanded just the same
	auto f = withMizu("immediates.doir");
	scope(exit) freeModule(f.mod);

	auto block = BlockBuilder(f.root, &f.mod);
	immutable u64 = resolveLookupName(f.mod, internIn(f.mod, "mizu.u64"), f.root);

	// What a `compiler.*` call `opt.computeCompilerNamespace` folded looks
	// like: still a call, with the value it comes to alongside it.
	immutable n = pushNumber(block, internIn(f.mod, "n"), u64, 1);
	immutable value = pushCall(block, internIn(f.mod, "v"), u64,
		resolveLookupName(f.mod, internIn(f.mod, "compiler.emit"), f.root), (&n)[0 .. 1]);
	getOrAddComponent!ComptimeNumber(f.mod, value).value = 1234;
	getOrAddComponent!AssignedRegister(f.mod, value).reg = 5;

	EntityId[2] args = [u64, value];
	immutable call = pushLoadImmediate(f, args[]);

	assert(materializeImmediates(f.mod, call));
	assert(hasComponent!Block(f.mod, call));
	assert(getComponent!AssignedRegister(f.mod, call).reg == 5);
	assert(!diagnostics().hasErrors());
	diagnostics().clear();
}

unittest { // a call with the wrong number of arguments is reported
	auto f = withMizu("immediates.doir");
	scope(exit) freeModule(f.mod);

	auto block = BlockBuilder(f.root, &f.mod);
	immutable u64 = resolveLookupName(f.mod, internIn(f.mod, "mizu.u64"), f.root);
	immutable value = pushNumber(block, internIn(f.mod, "v"), u64, 1);

	// One argument rather than two.
	assert(!materializeImmediates(f.mod, pushLoadImmediate(f, (&u64)[0 .. 1])));
	assert(diagnostics().hasErrors());
	diagnostics().clear();

	// ...and no arguments component at all.
	immutable argless = pushLoadImmediate(f, (&u64)[0 .. 1]);
	removeComponent!FunctionInputs(f.mod, argless);
	assert(!materializeImmediates(f.mod, argless));
	assert(diagnostics().hasErrors());
	diagnostics().clear();
	cast(void) value;
}

unittest { // ...as is one whose value is not a numeric constant
	auto f = withMizu("immediates.doir");
	scope(exit) freeModule(f.mod);

	auto block = BlockBuilder(f.root, &f.mod);
	immutable u64 = resolveLookupName(f.mod, internIn(f.mod, "mizu.u64"), f.root);
	immutable notANumber = pushValueless(block, internIn(f.mod, "v"), u64);

	EntityId[2] args = [u64, notANumber];
	assert(!materializeImmediates(f.mod, pushLoadImmediate(f, args[])));
	assert(diagnostics().hasErrors());
	diagnostics().clear();
}

unittest { // ...and one whose target was never assigned a register
	auto f = withMizu("immediates.doir");
	scope(exit) freeModule(f.mod);

	auto block = BlockBuilder(f.root, &f.mod);
	immutable u64 = resolveLookupName(f.mod, internIn(f.mod, "mizu.u64"), f.root);
	immutable value = pushNumber(block, internIn(f.mod, "v"), u64, 1);
	assert(!hasComponent!AssignedRegister(f.mod, value));

	EntityId[2] args = [u64, value];
	assert(!materializeImmediates(f.mod, pushLoadImmediate(f, args[])));
	assert(diagnostics().hasErrors());
	diagnostics().clear();
}

unittest { // anything that is not a `load_immediate` call is left alone
	auto f = withMizu("immediates.doir");
	scope(exit) freeModule(f.mod);

	auto block = BlockBuilder(f.root, &f.mod);
	immutable byte_ = resolveLookupName(f.mod, internIn(f.mod, "compiler.byte"), f.root);
	immutable emit = resolveLookupName(f.mod, internIn(f.mod, "compiler.emit"), f.root);

	immutable n = pushNumber(block, internIn(f.mod, "n"), byte_, 1);
	assert(materializeImmediates(f.mod, n)); // not a call

	immutable other = pushCall(block, InternedString("_"), byte_, emit, (&n)[0 .. 1]);
	assert(materializeImmediates(f.mod, other)); // a call to something else
	assert(!diagnostics().hasErrors());
	diagnostics().clear();
}

unittest {
	// A module with no mizu backend loaded resolves every `mizu.*` name to
	// `invalidEntity`, which is also what an unresolved callee is - so a call
	// with no target compared *equal* to `load_immediate` and was reported
	// against a synthesized entity, which aborts in `findSourceLocation`.
	auto f = makeModuleWithBuiltins();
	scope(exit) freeModule(f.mod);
	diagnostics().clear();

	immutable dangling = addEntity(f.mod);
	addComponent!Call(f.mod, dangling).related[0] = invalidEntity;
	assert(materializeImmediates(f.mod, dangling));
	assert(!diagnostics().hasErrors());
	diagnostics().clear();
}
