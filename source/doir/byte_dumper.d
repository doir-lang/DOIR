/// The temporary byte-emitting interpreter: walks a finished block and
/// concatenates whatever its `compiler.emit`/`compiler.emit_bytes` calls
/// name, producing the Mizu binary. Ported from temp_byte_dumper.hpp.
module doir.byte_dumper;

import ecrs.storage : EntityId;

static import fp.dynarray;
import fp.dynarray : daLength = length;

import doir.interface_;
import doir.module_;

@nogc nothrow:


/// One entity's emitted bytes.
private struct ByteBuffer {
	ubyte* data = null;

	@nogc nothrow:
	size_t length() const @trusted { return daLength(cast(ubyte*) data); }
	void free() @trusted { if (data !is null) { fp.dynarray.free(data); data = null; } }
}

/// An owning byte string.
struct ByteArray {
	ubyte* data = null;

	@nogc nothrow:
	size_t length() const @trusted { return daLength(cast(ubyte*) data); }
	inout(ubyte)[] slice() inout @trusted {
		return data is null ? null : (cast(inout(ubyte)*) data)[0 .. length()];
	}
	void push(ubyte b) @trusted { fp.dynarray.pushBack(data, b); }
	void free() @trusted { if (data !is null) { fp.dynarray.free(data); data = null; } }
}

/// Holds the per-entity byte values while walking a block.
struct ByteDumper {
	private ByteBuffer* values = null;

	@nogc nothrow:

	void free() @trusted {
		if (values is null) return;
		foreach (i; 0 .. daLength(values))
			values[i].free();
		fp.dynarray.free(values);
		values = null;
	}

	private void ensureSlot(EntityId e) @trusted {
		immutable want = cast(size_t) e * 2;
		while (daLength(values) <= e)
			fp.dynarray.pushBack(values, ByteBuffer.init);
		cast(void) want;
	}
}

private void interpretNumberAssign(ref ByteDumper self, ref ByteArray out_, ref Module mod, EntityId subtree) @trusted {
	if (hasComponent!Number(mod, subtree)) {
		immutable byteType = resolveLookupName(mod, internIn(mod, "compiler.byte"), 1);
		if (resolveAlias(mod, getComponent!TypeOf(mod, subtree).related[0]) != byteType) return;

		immutable value = cast(size_t) getComponent!Number(mod, subtree).value;
		self.ensureSlot(subtree);
		self.values[subtree].free();
		fp.dynarray.pushBack(self.values[subtree].data, cast(ubyte) value);
		return;
	}

	if (hasComponent!DString(mod, subtree)) {
		immutable bytePointer = resolveLookupName(mod, internIn(mod, "compiler.byte_pointer"), 1);
		if (resolveAlias(mod, getComponent!TypeOf(mod, subtree).related[0]) != bytePointer) return;

		auto value = getComponent!DString(mod, subtree).value;
		self.ensureSlot(subtree);
		self.values[subtree].free();
		foreach (c; value.view)
			fp.dynarray.pushBack(self.values[subtree].data, cast(ubyte) c);
		return;
	}
}

private void interpretCall(ref ByteDumper self, ref ByteArray out_, ref Module mod, EntityId subtree) @trusted {
	if (!hasComponent!Call(mod, subtree)) return;
	if (findFunctionInsideOf(mod, subtree)) return;

	immutable emit = resolveLookupName(mod, internIn(mod, "compiler.emit"), 1, true);
	immutable emitBytes = resolveLookupName(mod, internIn(mod, "compiler.emit_bytes"), 1, true);

	immutable function_ = resolveAlias(mod, getComponent!Call(mod, subtree).related[0]);
	auto inputs = &getComponent!FunctionInputs(mod, subtree);

	if (function_ == emit) {
		immutable source = resolveAlias(mod, inputs.related[0]);
		assert(source < daLength(self.values));
		assert(self.values[source].length > 0);
		out_.push(self.values[source].data[0]);
	} else if (function_ == emitBytes) {
		immutable source = resolveAlias(mod, inputs.related[0]);
		assert(source < daLength(self.values));
		foreach (i; 0 .. self.values[source].length)
			out_.push(self.values[source].data[i]);
	}
}

private void interpretBlock(ref ByteDumper self, ref ByteArray out_, ref Module mod, EntityId subtree) @trusted {
	assert(hasComponent!Block(mod, subtree));

	for (size_t i = 0; i < daLength(getComponent!Block(mod, subtree).related); ++i) {
		immutable e = getComponent!Block(mod, subtree).related[i];
		if (hasComponent!Block(mod, e))
			interpretBlock(self, out_, mod, e);
		else {
			interpretNumberAssign(self, out_, mod, e);
			interpretCall(self, out_, mod, e);
		}
	}
}

/// Walks `root`, returning the bytes it emits. The caller frees the result.
ByteArray interpret(ref ByteDumper self, ref Module mod, EntityId root) {
	ByteArray out_;
	interpretBlock(self, out_, mod, root);
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
	scope(exit) free(mod);

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

	ByteDumper dumper;
	scope(exit) dumper.free();
	auto bytes = interpret(dumper, mod, newRoot);
	scope(exit) bytes.free();

	assert(bytes.slice == cast(const(ubyte)[]) "Hello World");
	diagnostics().clear();
}

unittest { // calling compiler.emit through an alias still emits
	auto r = compile(
		"emit_alias : alias = compiler.emit\n"
		~ "%0 : compiler.byte = 0x44\n"
		~ "%1 : compiler.byte = emit_alias(%0)\n");
	scope(exit) free(r.mod);
	assert(r.ok);
	static immutable ubyte[1] expected = [0x44];
	assert(emits(r, expected[]));
}
