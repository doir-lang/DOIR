/// The temporary byte emiter: walks a finished block and
/// concatenates whatever its `compiler.emit`/`compiler.emit_bytes` calls
/// name, producing the Mizu binary. Ported from temp_byte_dumper.hpp.
module doir.byte_emiter;

import ecrs.storage : EntityId;

static import fp.dynarray;
import fp.dynarray : daLength = length;

import doir.interface_;
import doir.module_;

@nogc nothrow:


/// The slot holding entity `e`'s emitted bytes, grown into existence and
/// cleared: `opt.computeCompilerNamespace` can fold the same entity twice.
private ubyte** slotFor(ref ubyte** values, EntityId e) @trusted {
	while (daLength(values) <= e)
		fp.dynarray.pushBack(values, cast(ubyte*) null);
	fp.dynarray.free(values[e]);
	return &values[e];
}

private void emitNumberAssign(ref ubyte** values, ref Module mod, EntityId subtree) @trusted {
	// Either kind of constant is a byte here - `opt.computeCompilerNamespace`
	// leaves a `ComptimeNumber` behind on a folded `compiler.truncate_to_byte` /
	// `shift_right` call, and `mizu`'s `emit_register` hands exactly those to
	// `compiler.emit`.
	auto number = comptimeNumber(mod, subtree);
	if (!number.isNull) {
		// A folded call keeps its `TypeOf`; one that *replaced* itself does not.
		// A comptime instruction that turns its own call into a type or an alias
		// (`mizu.doir.type_pointer`, the M-Flag family) leaves both the
		// `ComptimeNumber` the evaluator writes back and no declared type, and
		// an entity with no declared type is certainly not a byte.
		if (!hasComponent!TypeOf(mod, subtree)) return;

		immutable byteType = resolveLookupName(mod, internIn(mod, "compiler.byte"), 1);
		if (resolveAlias(mod, getComponent!TypeOf(mod, subtree).related[0]) != byteType) return;

		fp.dynarray.pushBack(*slotFor(values, subtree), cast(ubyte) cast(size_t) number.get);
		return;
	}

	if (hasComponent!DString(mod, subtree)) {
		if (!hasComponent!TypeOf(mod, subtree)) return;

		immutable bytePointer = resolveLookupName(mod, internIn(mod, "compiler.byte_pointer"), 1);
		if (resolveAlias(mod, getComponent!TypeOf(mod, subtree).related[0]) != bytePointer) return;

		auto slot = slotFor(values, subtree);
		foreach (c; getComponent!DString(mod, subtree).value.view)
			fp.dynarray.pushBack(*slot, cast(ubyte) c);
	}
}

private void emitCall(ref ubyte** values, ref ubyte* out_, ref Module mod, EntityId subtree) @trusted {
	if (!hasComponent!Call(mod, subtree)) return;

	// A function body is a declaration nothing jumps to, so its bytes would
	// land in the middle of the caller's stream. A body that *is* jumped to
	// does not reach here as one: `opt.liftFunctionBodies` has already moved
	// it out to module scope, labels and all, so this asks what it says it
	// asks rather than standing in for "and not one with labels".
	if (findFunctionInsideOf(mod, subtree)) return;

	immutable emit = resolveLookupName(mod, internIn(mod, "compiler.emit"), 1, true);
	immutable emitBytes = resolveLookupName(mod, internIn(mod, "compiler.emit_bytes"), 1, true);

	immutable function_ = resolveAlias(mod, getComponent!Call(mod, subtree).related[0]);
	if (function_ != emit && function_ != emitBytes) return;

	immutable source = resolveAlias(mod, getComponent!FunctionInputs(mod, subtree).related[0]);
	assert(source < daLength(values));

	if (function_ == emit) {
		assert(daLength(values[source]) > 0);
		fp.dynarray.pushBack(out_, values[source][0]);
	} else {
		foreach (i; 0 .. daLength(values[source]))
			fp.dynarray.pushBack(out_, values[source][i]);
	}
}

/// Fills `values` for every constant in the tree, ahead of any emission.
///
/// A pass of its own rather than a step inside `emitBlock`, because where a
/// constant is *declared* has nothing to do with where the instruction naming
/// it is emitted: `compiler.emit(m.val)` at module scope reads a byte out of a
/// namespace, and `opt.sinkDeclarations` moves every namespace below the code.
/// Filling the table lazily during the emitting walk made a `compiler.emit`
/// that ran before the walk reached its operand an out-of-range index instead.
private void collectValues(ref ubyte** values, ref Module mod, EntityId subtree) @trusted {
	for (size_t i = 0; i < daLength(getComponent!Block(mod, subtree).related); ++i) {
		immutable e = getComponent!Block(mod, subtree).related[i];
		if (hasComponent!Block(mod, e)) collectValues(values, mod, e);
		else emitNumberAssign(values, mod, e);
	}
}

private void emitBlock(ref ubyte** values, ref ubyte* out_, ref Module mod, EntityId subtree) @trusted {
	assert(hasComponent!Block(mod, subtree));

	for (size_t i = 0; i < daLength(getComponent!Block(mod, subtree).related); ++i) {
		immutable e = getComponent!Block(mod, subtree).related[i];
		if (hasComponent!Block(mod, e))
			emitBlock(values, out_, mod, e);
		else
			emitCall(values, out_, mod, e);
	}
}

/// Walks `root`, returning the bytes it emits as a libfp dynarray the caller
/// frees with `fp.dynarray.free`. The per-entity scratch is internal: every
/// caller only ever built one, handed it straight here and freed it again.
ubyte* emitAll(ref Module mod, EntityId root) @trusted {
	ubyte** values = null; // indexed by entity
	scope(exit) {
		foreach (i; 0 .. daLength(values))
			fp.dynarray.free(values[i]);
		fp.dynarray.free(values);
	}

	ubyte* out_;
	collectValues(values, mod, root);
	emitBlock(values, out_, mod, root);
	return out_;
}


// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
// Ported from tests/pipeline.test.cpp, plus the `compiler.emit`-through-an-
// alias case of tests/spec_syntax.test.cpp.

version (unittest) {
	import ecrs.storage : invalidEntity;

	import doir.diagnostics;
	import doir.parser : parseSource;
	import doir.pipeline : runPipeline;
	import doir.pipeline.canon.sort : newRoot;

	import tests.pipeline_helper;
}

unittest {
	// Drives the exact pipeline the driver uses for a real compile, including
	// `canonicalize.sort` - a pass that physically renumbers entities.
	//
	// Mirrors test_string.doir: `compiler.byte` constants each immediately
	// emitted. It doesn't touch the `mizu` namespace, so it needs no
	// early_include of mizu.doir from disk, keeping the test hermetic.
	static immutable string source =
		"%0 : compiler.byte = 0x48\n"
		~ "%1 : compiler.byte = compiler.emit(%0)\n"
		~ "%2 : compiler.byte = 0x65\n"
		~ "%3 : compiler.byte = compiler.emit(%2)\n"
		~ "%4 : compiler.byte = 0x6c\n"
		~ "%5 : compiler.byte = compiler.emit(%4)\n"
		~ "%6 : compiler.byte = 0x6c\n"
		~ "%7 : compiler.byte = compiler.emit(%6)\n"
		~ "%8 : compiler.byte = 0x6f\n"
		~ "%9 : compiler.byte = compiler.emit(%8)\n"
		~ "%10 : compiler.byte = 0x20\n"
		~ "%11 : compiler.byte = compiler.emit(%10)\n"
		~ "%12 : compiler.byte = 0x57\n"
		~ "%13 : compiler.byte = compiler.emit(%12)\n"
		~ "%14 : compiler.byte = 0x6f\n"
		~ "%15 : compiler.byte = compiler.emit(%14)\n"
		~ "%16 : compiler.byte = 0x72\n"
		~ "%17 : compiler.byte = compiler.emit(%16)\n"
		~ "%18 : compiler.byte = 0x6c\n"
		~ "%19 : compiler.byte = compiler.emit(%18)\n"
		~ "%20 : compiler.byte = 0x64\n"
		~ "%21 : compiler.byte = compiler.emit(%20)\n";

	diagnostics().clear();
	auto mod = createModule();
	scope(exit) freeModule(mod);

	auto builders = createBuilderStack(mod);
	scope(exit) fp.dynarray.free(builders);

	assert(parseSource(mod, builders, source, "test_string.doir"));
	immutable root = runPipeline(mod, builders);
	assert(root != invalidEntity);
	assert(!diagnostics().hasErrors());

	internIn(mod, "compiler.emit");
	internIn(mod, "compiler.emit_bytes");

	auto bytes = emitAll(mod, newRoot);
	scope(exit) fp.dynarray.free(bytes);

	assert(fp.dynarray.slice(bytes) == cast(const(ubyte)[]) "Hello World");
	diagnostics().clear();
}

unittest { // calling compiler.emit through an alias still emits
	auto r = compile(
		"emit_alias : alias = compiler.emit\n"
		~ "%0 : compiler.byte = 0x44\n"
		~ "%1 : compiler.byte = emit_alias(%0)\n");
	scope(exit) freeModule(r.mod);
	assert(r.ok);
	static immutable ubyte[1] expected = [0x44];
	assert(emits(r, expected[]));
}
