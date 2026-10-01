/// `opt.mizu.materializeImmediates`: expands a `mizu.load_immediate` call
/// into the byte sequence that encodes the instruction. Ported from
/// opt/mizu/materialize_immediates.hpp.
///
/// `mizu.load_u64_immediate` and `mizu.load_f64_immediate` expand here too:
/// they are the same encoding done twice, since a Mizu immediate is 32 bits
/// wide and the second instruction carries the half that did not fit.
module doir.pipeline.opt.mizu.materialize_immediates;

import core.stdc.stdio : snprintf;

import ecrs.storage : EntityId, invalidEntity;

static import fp.dynarray;
import fp.dynarray : daLength = length;

import doir.interface_;
import doir.module_;
import doir.diagnostics;
import doir.pipeline.canon.sort : loweringThrowawayBlock;
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
	immutable loadU64Immediate = resolveCached(mod, "mizu.load_u64_immediate", 1);
	immutable loadF64Immediate = resolveCached(mod, "mizu.load_f64_immediate", 1);

	immutable function_ = resolveAlias(mod, getComponent!Call(mod, subtree).related[0]);
	// `invalidEntity` is 0, and it is what both an unresolved callee and an
	// unresolvable `resolveCached` name come back as - so "neither resolved"
	// compared *equal* here. A module that never included mizu.doir (so every
	// `mizu.*` above is 0) and holds a call whose target is 0 was therefore
	// treated as a `load_immediate`, and reported "load_immediate expects two
	// inputs" against a synthesized entity, which aborts in
	// `findSourceLocation`. An unresolved callee is not any of these.
	if (function_ == invalidEntity) return true;
	if (!(function_ == loadImmediate || function_ == loadUpperImmediate
		|| function_ == loadU64Immediate || function_ == loadF64Immediate)) return true;

	immutable(char)[] name = function_ == loadUpperImmediate ? "load_upper_immediate"
		: function_ == loadU64Immediate ? "load_u64_immediate"
		: function_ == loadF64Immediate ? "load_f64_immediate" : "load_immediate";

	if (!hasComponent!FunctionInputs(mod, subtree)) {
		expectsXInputs(mod, subtree, name, "two");
		return false;
	}

	auto inputs = resolvedInputs(mod, subtree);
	scope(exit) fp.dynarray.free(inputs);
	if (daLength(inputs) != 2) {
		expectsXInputs(mod, subtree, name, "two");
		return false;
	}

	auto constant = comptimeNumber(mod, inputs[1]);
	if (constant.isNull) {
		// A parameter, so this is the declaration of a function that wraps the
		// load rather than a call of one - `std.transition_comptime_to_runtime`
		// is the wrapper, and its body is walked whether or not anything calls
		// it. The constant exists only in the copy a call site gets, which is
		// why `standard.mizu.doir` schedules this pass a second time after the
		// inlining. Nothing else reaches here with an argument that is not a
		// value, so the test is the whole of the distinction.
		if (hasComponent!FunctionParameter(mod, inputs[1])) return true;
		// TODO: It would probably be good to relax this constraint in the future
		parameterError(mod, subtree, name, 0, " must evaluate to a numeric constant");
		return false;
	}

	immutable target = inputs[1];

	// TODO: Some sort of actual register allocation logic would be nice
	// Asked before the surgery below rather than halfway through it, so a
	// rejected call is left intact the way every rejection above leaves it.
	if (!hasComponent!AssignedRegister(mod, target)) {
		// A block lowered for comptime runs this schedule with the module still
		// around it, and `ownedByCurrentLowering` hands unclaimed code to the
		// fallback schedule - which is this one. So the walk reaches calls out
		// there too, where the register round the outer schedule has not run
		// yet is what would have given them one. Not this run's call.
		if (loweringThrowawayBlock()) return true;
		noAssociatedRegister(mod, subtree, target);
		return false;
	}
	immutable r = getComponent!AssignedRegister(mod, target).reg;

	// `load_immediate` and `load_upper_immediate` encode the one instruction
	// they name and truncate to it - `opt.mizu.comptimeEvaluate` pairs them by
	// hand off two entities. The `_u64`/`_f64` forms take the whole value and
	// split it themselves: an integer straight across (`real` carries a 64 bit
	// mantissa, so the conversion is exact over the range), a float as the bit
	// pattern of the double rather than its value.
	immutable bool splits = function_ == loadU64Immediate || function_ == loadF64Immediate;
	ulong value;
	if (function_ == loadF64Immediate) {
		immutable double d = cast(double) constant.get;
		value = *cast(const(ulong)*) &d;
	} else if (function_ == loadU64Immediate)
		value = cast(ulong) constant.get;
	else
		value = cast(uint) constant.get;

	immutable type = getComponent!TypeOf(mod, subtree).related[0];
	removeComponent!TypeOf(mod, subtree);
	removeComponent!Call(mod, subtree);
	auto builder = attachSubblock(mod, subtree, type);
	{
		getOrAddComponent!AssignedRegister(mod, subtree).reg = r;

		/// One instruction: the `_op` call, the register, the 32 bit immediate,
		/// and the padding out to the operand width. `tag` keeps the two
		/// copies' declaration names apart.
		void encode(EntityId op, uint immediate, const(char)[] tag) @trusted {
			EntityId[1] opInputs = [u64];
			immutable c = pushCall(builder, InternedString("_"), u64, op, opInputs[]);
			getOrAddComponent!Flags(mod, c).flags = Flags.Inline;

			char[32] buffer;
			EntityId[1] emitInputs;

			immutable nLow = snprintf(buffer.ptr, buffer.length, "low%.*s",
				cast(int) tag.length, tag.ptr);
			emitInputs[0] = pushNumber(builder, internIn(mod, buffer[0 .. nLow]), byteType,
				cast(ubyte)(r & 0xFF));
			pushCall(builder, InternedString("_"), byteType, emit, emitInputs[]);

			immutable nHigh = snprintf(buffer.ptr, buffer.length, "high%.*s",
				cast(int) tag.length, tag.ptr);
			emitInputs[0] = pushNumber(builder, internIn(mod, buffer[0 .. nHigh]), byteType,
				cast(ubyte)((r >> 8) & 0xFF));
			pushCall(builder, InternedString("_"), byteType, emit, emitInputs[]);

			auto bytes = (cast(const(ubyte)*) &immediate)[0 .. uint.sizeof];
			foreach (i; 0 .. bytes.length) {
				immutable n = snprintf(buffer.ptr, buffer.length, "%%%zu%.*s",
					i, cast(int) tag.length, tag.ptr);
				emitInputs[0] = pushNumber(builder, internIn(mod, buffer[0 .. n]), byteType,
					cast(int) bytes[i]);
				pushCall(builder, InternedString("_"), byteType, emit, emitInputs[]);
			}

			immutable nZero = snprintf(buffer.ptr, buffer.length, "zero%.*s",
				cast(int) tag.length, tag.ptr);
			emitInputs[0] = pushNumber(builder, internIn(mod, buffer[0 .. nZero]), byteType, 0);
			foreach (_; 0 .. 2) // Need to fill in another uint16_t
				pushCall(builder, InternedString("_"), byteType, emit, emitInputs[]);
		}

		if (splits) {
			encode(loadImmediateOp, cast(uint) value, "");
			// `load_immediate` clears the whole register, so the upper half has
			// to follow it - and only when there is one, which is what makes a
			// value that fits cost a single instruction.
			if (value >> 32) encode(loadUpperImmediateOp, cast(uint)(value >> 32), "_upper");
		} else
			encode(function_ == loadImmediate ? loadImmediateOp : loadUpperImmediateOp,
				cast(uint) value, "");

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


	/// `<callee>(args...)` pushed into the fixture's root block.
	private EntityId pushLoad(ref PipelineResult f, const(char)[] callee, const(EntityId)[] args) {
		auto block = BlockBuilder(f.root, &f.mod);
		immutable u64 = resolveLookupName(f.mod, internIn(f.mod, "mizu.u64"), f.root);
		immutable function_ = resolveLookupName(f.mod, internIn(f.mod, callee), f.root);
		assert(function_ != invalidEntity);
		return pushCall(block, InternedString("_"), u64, function_, args);
	}

	/// `mizu.load_immediate(args...)` pushed into the fixture's root block.
	private EntityId pushLoadImmediate(ref PipelineResult f, const(EntityId)[] args) {
		return pushLoad(f, "mizu.load_immediate", args);
	}

	/// The declaration named `name` among `expanded`'s children, or
	/// `invalidEntity`. The expansion names the bytes it pushes, which is how a
	/// test reads an encoded immediate back out of it.
	private EntityId declaration(ref Module mod, EntityId expanded, const(char)[] name) {
		auto interned = internIn(mod, name);
		auto block = &getComponent!Block(mod, expanded);
		foreach (i; 0 .. daLength(block.related)) {
			immutable e = block.related[i];
			if (hasComponent!Name(mod, e) && getComponent!Name(mod, e).value == interned)
				return e;
		}
		return invalidEntity;
	}

	/// The 32 bit immediate the instruction tagged `tag` encodes.
	private uint encodedImmediate(ref Module mod, EntityId expanded, const(char)[] tag) {
		uint value;
		foreach (size_t i; 0 .. 4) {
			char[32] buffer;
			immutable n = snprintf(buffer.ptr, buffer.length, "%%%zu%.*s",
				i, cast(int) tag.length, tag.ptr);
			immutable e = declaration(mod, expanded, buffer[0 .. n]);
			assert(e != invalidEntity);
			value |= cast(uint)(cast(ulong) getComponent!Number(mod, e).value) << (8 * i);
		}
		return value;
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

unittest { // `load_u64_immediate` is one instruction while the value fits...
	auto f = withMizu("immediates.doir");
	scope(exit) freeModule(f.mod);

	auto block = BlockBuilder(f.root, &f.mod);
	immutable u64 = resolveLookupName(f.mod, internIn(f.mod, "mizu.u64"), f.root);
	immutable value = pushNumber(block, internIn(f.mod, "v"), u64, 0x89ABCDEF);
	getOrAddComponent!AssignedRegister(f.mod, value).reg = 5;

	EntityId[2] args = [u64, value];
	immutable call = pushLoad(f, "mizu.load_u64_immediate", args[]);

	assert(materializeImmediates(f.mod, call));
	assert(getComponent!AssignedRegister(f.mod, call).reg == 5);
	assert(encodedImmediate(f.mod, call, "") == 0x89ABCDEF);
	assert(declaration(f.mod, call, "%0_upper") == invalidEntity);
	assert(!diagnostics().hasErrors());
	diagnostics().clear();
}

unittest { // ...and two once it does not
	auto f = withMizu("immediates.doir");
	scope(exit) freeModule(f.mod);

	auto block = BlockBuilder(f.root, &f.mod);
	immutable u64 = resolveLookupName(f.mod, internIn(f.mod, "mizu.u64"), f.root);
	immutable value = pushNumber(block, internIn(f.mod, "v"), u64, 0x1234_5678_9ABC_DEF0);
	getOrAddComponent!AssignedRegister(f.mod, value).reg = 5;

	EntityId[2] args = [u64, value];
	immutable call = pushLoad(f, "mizu.load_u64_immediate", args[]);

	assert(materializeImmediates(f.mod, call));
	assert(encodedImmediate(f.mod, call, "") == 0x9ABCDEF0);
	assert(encodedImmediate(f.mod, call, "_upper") == 0x1234_5678);
	assert(!diagnostics().hasErrors());
	diagnostics().clear();
}

unittest { // `load_f64_immediate` encodes the double's bits rather than its value
	auto f = withMizu("immediates.doir");
	scope(exit) freeModule(f.mod);

	auto block = BlockBuilder(f.root, &f.mod);
	immutable u64 = resolveLookupName(f.mod, internIn(f.mod, "mizu.u64"), f.root);
	immutable value = pushNumber(block, internIn(f.mod, "v"), u64, 5.5);
	getOrAddComponent!AssignedRegister(f.mod, value).reg = 5;

	EntityId[2] args = [u64, value];
	immutable call = pushLoad(f, "mizu.load_f64_immediate", args[]);

	assert(materializeImmediates(f.mod, call));
	// 5.5 is 0x4016000000000000, so the low half is a whole instruction's
	// worth of zeroes that the upper one still has to follow.
	assert(encodedImmediate(f.mod, call, "") == 0);
	assert(encodedImmediate(f.mod, call, "_upper") == 0x4016_0000);
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
