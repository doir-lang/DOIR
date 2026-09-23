/// `opt.mizu.materializeLabels`: hands every `mizu.label()` call a label id of
/// its own and expands it into the byte sequence that encodes the instruction.
///
/// `mizu.doir` binds `label` as an empty function, the way it binds
/// `load_immediate`, because neither can be written in DOIR: the bytes a
/// `label` encodes include a value nothing in the source names. That value is
/// also what `mizu.find_label(l)` searches the program for, so the two have to
/// agree - hence the counter here, and the `ComptimeNumber` left behind on the
/// call, which is what `find_label`'s body
/// (`compiler.truncate_to_byte(label)` and the shifts beside it) folds into the
/// immediate it emits.
module doir.pipeline.opt.mizu.materialize_labels;


import ecrs.storage : EntityId, invalidEntity;

import doir.interface_;
import doir.module_;
import doir.string_helpers : InternedString;

@nogc nothrow:


/// The next label id to hand out. Process-wide, like
/// `compute_compiler_namespace`'s `nextUnique` counter: ids only have to be
/// distinct within one program, and never reusing one at all is a stronger
/// promise than that rather than a weaker one.
private __gshared uint nextLabelId = 1;

bool materializeLabels(ref Module mod, EntityId subtree) @trusted {
	if (!hasComponent!Call(mod, subtree)) return true;

	immutable u64 = resolveCached(mod, "mizu.u64", 1);
	immutable byteType = resolveCached(mod, "compiler.byte", 1);
	immutable emit = resolveCached(mod, "compiler.emit", 1);
	immutable indicateYield = resolveCached(mod, "compiler.indicate_yield", 1);
	immutable label = resolveCached(mod, "mizu.label", 1);
	immutable labelOp = resolveCached(mod, "mizu.label_op", 1);

	immutable function_ = resolveAlias(mod, getComponent!Call(mod, subtree).related[0]);
	// `invalidEntity` is 0, and so is an unresolvable `mizu.*` name - so in a
	// module that never included mizu.doir a call with no target would compare
	// equal to `label` here. See the same guard in `materializeImmediates`.
	if (function_ == invalidEntity) return true;
	if (function_ != label) return true;

	immutable value = nextLabelId++;

	immutable type = getComponent!TypeOf(mod, subtree).related[0];
	removeComponent!TypeOf(mod, subtree);
	removeComponent!Call(mod, subtree);
	auto builder = attachSubblock(mod, subtree, type);
	{
		EntityId[0] noInputs;
		immutable c = pushCall(builder, InternedString("_"), u64, labelOp, noInputs[]);
		getOrAddComponent!Flags(mod, c).flags = Flags.Inline;

		// `label_op` emits the instruction id; what is left of the `Opcode` is
		// an `out_` the instruction never reads, the id as a `u32` immediate,
		// and the two bytes of tail padding every `Opcode` carries.
		EntityId[1] emitInputs;
		emitInputs[0] = pushNumber(builder, internIn(mod, "zero"), byteType, 0);
		foreach (_; 0 .. 2)
			pushCall(builder, InternedString("_"), byteType, emit, emitInputs[]);

		auto bytes = (cast(const(ubyte)*) &value)[0 .. uint.sizeof];
		foreach (i; 0 .. bytes.length) {
			immutable e = pushNumber(builder, positionalName(mod, i), byteType,
				cast(int) bytes[i]);
			pushCall(builder, InternedString("_"), byteType, emit, (&e)[0 .. 1]);
		}

		foreach (_; 0 .. 2)
			pushCall(builder, InternedString("_"), byteType, emit, emitInputs[]);

		EntityId[1] yieldInputs = [type];
		pushCall(builder, InternedString("_"), type, indicateYield, yieldInputs[]);
	}
	builder.end();

	// What `find_label` reads back out. A `ComptimeNumber` rather than a
	// `Number` because the two say different things: a `Number` would make the
	// entity *be* that constant, which the block above already contradicts -
	// `verify.structure` rejects an entity that is both a constant and a block
	// - whereas a `ComptimeNumber` says only that the compiler knows what the
	// block's value works out to, which is exactly the case here.
	getOrAddComponent!ComptimeNumber(mod, subtree).value = value;
	return true;
}


// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest) {
	static import fp.dynarray;
	import fp.dynarray : daLength = length;

	import doir.diagnostics;
	import tests.pipeline_helper : compile, makeModuleWithBuiltins, PipelineResult, withMizu;


	/// `mizu.label()` pushed into the fixture's root block.
	private EntityId pushLabel(ref PipelineResult f) {
		auto block = BlockBuilder(f.root, &f.mod);
		immutable register = resolveLookupName(f.mod,
			internIn(f.mod, "compiler.assembler.register"), f.root);
		immutable label = resolveLookupName(f.mod, internIn(f.mod, "mizu.label"), f.root);
		assert(label != invalidEntity);
		EntityId[0] noInputs;
		return pushCall(block, internIn(f.mod, "l"), register, label, noInputs[]);
	}
}

unittest { // a label call becomes the block that encodes it, plus its id
	auto f = withMizu("labels.doir");
	scope(exit) freeModule(f.mod);

	immutable call = pushLabel(f);
	assert(materializeLabels(f.mod, call));

	assert(!hasComponent!Call(f.mod, call));
	assert(hasComponent!Block(f.mod, call));
	assert(hasComponent!ComptimeNumber(f.mod, call));
	// `label_op`, the shared zero byte, the two `out_` bytes, the four bytes
	// of the id and their constants, the two padding bytes, and the yield.
	assert(daLength(getComponent!Block(f.mod, call).related) == 1 + 1 + 2 + 8 + 2 + 1);
	assert(!diagnostics().hasErrors());
	diagnostics().clear();
}

unittest { // every call gets an id of its own, one after another
	auto f = withMizu("labels.doir");
	scope(exit) freeModule(f.mod);

	immutable first = pushLabel(f);
	immutable second = pushLabel(f);
	assert(materializeLabels(f.mod, first));
	assert(materializeLabels(f.mod, second));

	immutable a = getComponent!ComptimeNumber(f.mod, first).value;
	immutable b = getComponent!ComptimeNumber(f.mod, second).value;
	assert(b == a + 1);

	// ...and running the pass again over one that has already been expanded
	// leaves it alone rather than burning another id on it.
	assert(materializeLabels(f.mod, first));
	assert(getComponent!ComptimeNumber(f.mod, first).value == a);
	assert(!diagnostics().hasErrors());
	diagnostics().clear();
}

unittest { // anything that is not a `mizu.label` call is left alone
	auto f = withMizu("labels.doir");
	scope(exit) freeModule(f.mod);

	auto block = BlockBuilder(f.root, &f.mod);
	immutable byte_ = resolveLookupName(f.mod, internIn(f.mod, "compiler.byte"), f.root);
	immutable emit = resolveLookupName(f.mod, internIn(f.mod, "compiler.emit"), f.root);

	immutable n = pushNumber(block, internIn(f.mod, "n"), byte_, 1);
	assert(materializeLabels(f.mod, n)); // not a call

	immutable other = pushCall(block, InternedString("_"), byte_, emit, (&n)[0 .. 1]);
	assert(materializeLabels(f.mod, other)); // a call to something else
	assert(hasComponent!Call(f.mod, other));
	assert(!diagnostics().hasErrors());
	diagnostics().clear();
}

unittest {
	// A module with no mizu backend loaded resolves `mizu.label` to
	// `invalidEntity`, which is also what a call with no target holds - so
	// without the guard the two compare equal and the pass expands a call it
	// knows nothing about.
	auto f = makeModuleWithBuiltins();
	scope(exit) freeModule(f.mod);
	diagnostics().clear();

	immutable dangling = addEntity(f.mod);
	addComponent!Call(f.mod, dangling).related[0] = invalidEntity;
	assert(materializeLabels(f.mod, dangling));
	assert(hasComponent!Call(f.mod, dangling));
	assert(!diagnostics().hasErrors());
	diagnostics().clear();
}

unittest {
	// End to end: the id the pass hands out is the one `find_label` goes
	// looking for. Each is a `u32` immediate in the `a`/`b` slots of its own
	// `Opcode`, and the program only works if the two agree - which is what
	// leaving the id behind as a `ComptimeNumber` buys, since that is what
	// `find_label`'s body folds into the bytes it emits.
	import doir.byte_emiter;
	import doir.pipeline.canon.sort : newRoot;

	auto r = compile(
		"path : compiler.byte_pointer = \"./mizu.doir\"\n"
		~ "_ : compiler.byte = early_include(path)\n"
		~ "_ : compiler.assembler.register = compiler.assembler.begin_register_allocation()\n"
		~ "top : compiler.assembler.register = mizu.label()\n"
		~ "_ : mizu.u64 = mizu.find_label(top)\n"
		~ "_ : mizu.u64 = mizu.halt()\n");
	scope(exit) freeModule(r.mod);
	assert(r.ok);

	internIn(r.mod, "compiler.emit");
	internIn(r.mod, "compiler.emit_bytes");
	auto bytes = emitAll(r.mod, newRoot);
	scope(exit) fp.dynarray.free(bytes);

	// Three `Opcode`s, sixteen bytes each: the label, the search for it, and
	// the halt. Each starts with its instruction id as a little-endian `u64`.
	auto slice = fp.dynarray.slice(bytes);
	assert(slice.length == 3 * 16);
	assert(slice[0] == 1);  // `label`
	assert(slice[16] == 2); // `find_label`
	assert(slice[32] == 3); // `halt`
	// The immediate of each sits past its id and its two `out_` bytes.
	assert(slice[10 .. 14] == slice[26 .. 30]);
	diagnostics().clear();
}
