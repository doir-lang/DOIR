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


/// One entity's emitted bytes.
private struct ByteBuffer {
	ubyte* data = null;
}

private size_t length(ref const ByteBuffer b) @trusted {
	return daLength(cast(ubyte*) b.data);
}

private void free(ref ByteBuffer b) @trusted {
	if (b.data !is null) { fp.dynarray.free(b.data); b.data = null; }
}

/// An owning byte string.
struct ByteArray {
	ubyte* data = null;
}

size_t length(ref const ByteArray a) @trusted {
	return daLength(cast(ubyte*) a.data);
}

inout(ubyte)[] slice(ref inout ByteArray a) @trusted {
	return a.data is null ? null : (cast(inout(ubyte)*) a.data)[0 .. length(a)];
}

void push(ref ByteArray a, ubyte b) @trusted {
	fp.dynarray.pushBack(a.data, b);
}

void free(ref ByteArray a) @trusted {
	if (a.data !is null) { fp.dynarray.free(a.data); a.data = null; }
}

/// Holds the per-entity byte values while walking a block.
struct ByteEmiter {
	ByteBuffer* values = null; // fp dynarray, indexed by entity
}

void free(ref ByteEmiter self) @trusted {
	if (self.values is null) return;
	foreach (i; 0 .. daLength(self.values))
		free(self.values[i]);
	fp.dynarray.free(self.values);
	self.values = null;
}

/// Makes sure `self.values` has a slot for entity `e`.
private void ensureSlot(ref ByteEmiter self, EntityId e) @trusted {
	while (daLength(self.values) <= e)
		fp.dynarray.pushBack(self.values, ByteBuffer.init);
}

private void emitNumberAssign(ref ByteEmiter self, ref ByteArray out_, ref Module mod, EntityId subtree) @trusted {
	// Either kind of constant is a byte here - `opt.computeCompilerNamespace`
	// leaves a `ComptimeNumber` behind on a folded `compiler.bitwise_and` /
	// `shift_right` call, and `mizu`'s `emit_register` hands exactly those to
	// `compiler.emit`.
	auto number = comptimeNumber(mod, subtree);
	if (!number.isNull) {
		immutable byteType = resolveLookupName(mod, internIn(mod, "compiler.byte"), 1);
		if (resolveAlias(mod, getComponent!TypeOf(mod, subtree).related[0]) != byteType) return;

		immutable value = cast(size_t) number.get;
		ensureSlot(self, subtree);
		free(self.values[subtree]);
		fp.dynarray.pushBack(self.values[subtree].data, cast(ubyte) value);
		return;
	}

	if (hasComponent!DString(mod, subtree)) {
		immutable bytePointer = resolveLookupName(mod, internIn(mod, "compiler.byte_pointer"), 1);
		if (resolveAlias(mod, getComponent!TypeOf(mod, subtree).related[0]) != bytePointer) return;

		auto value = getComponent!DString(mod, subtree).value;
		ensureSlot(self, subtree);
		free(self.values[subtree]);
		foreach (c; value.view)
			fp.dynarray.pushBack(self.values[subtree].data, cast(ubyte) c);
		return;
	}
}

private void emitCall(ref ByteEmiter self, ref ByteArray out_, ref Module mod, EntityId subtree) @trusted {
	if (!hasComponent!Call(mod, subtree)) return;
	if (findFunctionInsideOf(mod, subtree)) return;

	immutable emit = resolveLookupName(mod, internIn(mod, "compiler.emit"), 1, true);
	immutable emitBytes = resolveLookupName(mod, internIn(mod, "compiler.emit_bytes"), 1, true);

	immutable function_ = resolveAlias(mod, getComponent!Call(mod, subtree).related[0]);
	auto inputs = &getComponent!FunctionInputs(mod, subtree);

	if (function_ == emit) {
		immutable source = resolveAlias(mod, inputs.related[0]);
		assert(source < daLength(self.values));
		assert(length(self.values[source]) > 0);
		push(out_, self.values[source].data[0]);
	} else if (function_ == emitBytes) {
		immutable source = resolveAlias(mod, inputs.related[0]);
		assert(source < daLength(self.values));
		foreach (i; 0 .. length(self.values[source]))
			push(out_, self.values[source].data[i]);
	}
}

private void emitBlock(ref ByteEmiter self, ref ByteArray out_, ref Module mod, EntityId subtree) @trusted {
	assert(hasComponent!Block(mod, subtree));

	for (size_t i = 0; i < daLength(getComponent!Block(mod, subtree).related); ++i) {
		immutable e = getComponent!Block(mod, subtree).related[i];
		if (hasComponent!Block(mod, e))
			emitBlock(self, out_, mod, e);
		else {
			emitNumberAssign(self, out_, mod, e);
			emitCall(self, out_, mod, e);
		}
	}
}

/// Walks `root`, returning the bytes it emits. The caller frees the result.
ByteArray emitAll(ref ByteEmiter self, ref Module mod, EntityId root) {
	ByteArray out_;
	emitBlock(self, out_, mod, root);
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
	import doir.pipeline.sema.sort : newRoot;

	import tests.pipeline_helper;
}

unittest {
	// Drives the exact pipeline the driver uses for a real compile (parse ->
	// canonicalize -> sema -> optimize/comptime evaluate), which includes
	// `canonicalize.sort` - a pass that physically renumbers entities.
	//
	// This used to have to live in its own executable in the C++ build, because
	// resolution helpers memoized `lookup::resolve(...)` results in
	// function-local `static`s: once sort renumbered one module's entities,
	// those caches returned stale ids to every other test in the binary.
	// `resolveCached` is per-module and invalidated by sort, so this can live
	// alongside everything else.
	//
	// Mirrors test_string.doir (a real fixture checked into the repo root): a
	// sequence of `compiler.byte` constants each immediately emitted via
	// compiler.emit. It doesn't touch the `mizu` namespace, so it doesn't
	// require early_include-ing mizu.doir from disk, keeping this test hermetic.
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

	BlockBuilder* builders;
	scope(exit) fp.dynarray.free(builders);
	auto builtin = createBlockBuilder(mod);
	buildBuiltinBlock(builtin);
	fp.dynarray.pushBack(builders, builtin);

	assert(parseSource(mod, builders, source, "test_string.doir"));
	immutable root = runPipeline(mod, builders);
	assert(root != invalidEntity);
	assert(!diagnostics().hasErrors());

	internIn(mod, "compiler.emit");
	internIn(mod, "compiler.emit_bytes");

	ByteEmiter emiter;
	scope(exit) emiter.free();
	auto bytes = emitAll(emiter, mod, newRoot);
	scope(exit) bytes.free();

	assert(bytes.slice == cast(const(ubyte)[]) "Hello World");
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
