/// The test-side conveniences for driving a compile: building a module with
/// its builtins in place, running source text through the exact pipeline the
/// driver uses, finding things in the result, and checking what it emits.
/// Ported from tests/pipeline_helper.hpp and tests/fixtures.hpp.
///
/// The pipeline itself is `doir.pipeline` - the same code `main.d` runs - so
/// nothing here defines a schedule; it only sets modules up and takes them
/// apart again.
module tests.pipeline_helper;

import ecrs.storage : EntityId, invalidEntity;

static import fp.dynarray;

import doir.diagnostics;
import doir.interface_;
import doir.module_;
import doir.parser;
import doir.pipeline;

@nogc nothrow:


struct Fixture {
	Module mod;
	EntityId root;
}

/// Builds a fresh module and immediately populates it with the standard builtin
/// block (`type`, `block`, `compiler.*`, `compiler.assembler.*`, ...) - exactly
/// mirroring what the driver does before parsing any user source.
///
/// (Historical note: this used to carry a warning that every module in the
/// process had to build its builtin block identically, because the many
/// `static ecrs::entity_t X = lookup::resolve(mod, "compiler.foo", ...)` caches
/// throughout the codebase memoized their result in a function-local `static`
/// the first time they ran in the process, silently reusing that first
/// module's ids for every module built afterwards. That pattern has been
/// replaced by `resolveCached`, a per-module cache that `canonicalize.sort`
/// also invalidates - see doir/module_.d and the resolve-cache tests.)
Fixture makeModuleWithBuiltins() {
	Fixture f;
	f.mod = createModule();
	f.root = builtinBlockBuilder(f.mod).end();
	return f;
}

/// The open builtin block builder both `makeModuleWithBuiltins` and `compile`
/// start from: one ends it for the root id, the other leaves it open as
/// `builders[0]` the way the driver does.
private BlockBuilder builtinBlockBuilder(ref Module mod) {
	auto builder = createBlockBuilder(mod);
	buildBuiltinBlock(builder);
	return builder;
}


struct PipelineResult {
	bool ok;
	Module mod;
	EntityId root = invalidEntity;
}

/// Builds a fresh module + builtin block, then runs the pipeline over `source`.
PipelineResult compile(const(char)[] source, const(char)[] path = "test.doir") {
	// `diagnostics()` is a process-wide singleton - clear it here so a
	// diagnostic left over from an unrelated earlier test can't make *this*
	// compile's `ok` come back false too.
	diagnostics().clear();

	PipelineResult result;
	result.mod = createModule();

	BlockBuilder* builders; // the parser's stack of open blocks
	scope(exit) fp.dynarray.free(builders);
	fp.dynarray.pushBack(builders, builtinBlockBuilder(result.mod));

	if (parseSource(result.mod, builders, source, path) && !diagnostics().hasErrors())
		result.root = runPipeline(result.mod, builders);
	result.ok = result.root != invalidEntity && !diagnostics().hasErrors();
	return result;
}

/// Looks an entity up *by name* after a compile. Tests must do this rather
/// than hold onto the id they created something with, because
/// `canonicalize.sort` renumbers entities partway through the pipeline -
/// names travel with an entity across that renumbering, ids don't.
EntityId find(ref Module mod, EntityId root, const(char)[] name) {
	return resolveLookupName(mod, internIn(mod, name), root);
}

/// Runs the byte emiter over a finished compile and compares what it emits.
bool emits(ref PipelineResult r, const(ubyte)[] expected) {
	import doir.byte_emiter;
	import doir.pipeline.sema.sort : newRoot;

	internIn(r.mod, "compiler.emit");
	internIn(r.mod, "compiler.emit_bytes");

	ByteEmiter emiter;
	scope(exit) emiter.free();
	auto out_ = emitAll(emiter, r.mod, newRoot);
	scope(exit) out_.free();
	return out_.slice == expected;
}
