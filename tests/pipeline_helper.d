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
Fixture makeModuleWithBuiltins() {
	Fixture f;
	f.mod = createModule();
	auto builder = createBlockBuilder(f.mod);
	buildBuiltinBlock(builder);
	f.root = builder.end();
	return f;
}


/// The same module with the builtin block left *open* as `builders[0]`, the
/// way the driver leaves it for `parseSource`. Tests that hand-build IR push
/// into `builder` and end it themselves; tests that parse hand `builders`
/// straight to `parseSource`.
struct BuilderFixture {
	Module mod;
	BlockBuilder* builders;
	EntityId root = invalidEntity;
}

BuilderFixture makeOpenModule() @trusted {
	BuilderFixture f;
	f.mod = createModule();
	f.builders = createBuilderStack(f.mod);
	f.root = f.builders[0].block;
	return f;
}

ref BlockBuilder builder(return ref BuilderFixture f) @trusted { return f.builders[0]; }

/// Not `free`: one declared here would hide every imported `free` throughout
/// each module that imports this (see the note in README.md).
void freeFixture(ref BuilderFixture f) @trusted {
	fp.dynarray.free(f.builders);
	freeModule(f.mod);
}

/// Reopens the finished root, for passes whose tests hand-build IR into a
/// module whose builtins are already closed. The result holds `&f.mod`, so it
/// belongs in a local beside the fixture it was opened on - a fixture that
/// stored its own builder would be storing a pointer into itself.
BlockBuilder openRoot(return ref Fixture f) @trusted { return BlockBuilder(f.root, &f.mod); }


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

	auto builders = createBuilderStack(result.mod);
	scope(exit) fp.dynarray.free(builders);

	if (parseSource(result.mod, builders, source, path) && !diagnostics().hasErrors())
		result.root = runPipeline(result.mod, builders);
	result.ok = result.root != invalidEntity && !diagnostics().hasErrors();
	return result;
}

/// A module with `mizu.doir` included and taken through the pipeline, so every
/// `mizu.*` name a backend pass needs resolves. `path` is only what diagnostics
/// blame - the included file is always `./mizu.doir`, relative to the cwd.
PipelineResult withMizu(const(char)[] path) {
	auto r = compile(
		"path : compiler.byte_pointer = \"./mizu.doir\"\n"
		~ "_ : compiler.byte = early_include(path)\n", path);
	assert(r.ok);
	return r;
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
	import doir.pipeline.canon.sort : newRoot;

	internIn(r.mod, "compiler.emit");
	internIn(r.mod, "compiler.emit_bytes");

	auto out_ = emitAll(r.mod, newRoot);
	scope(exit) fp.dynarray.free(out_);
	return fp.dynarray.slice(out_) == expected;
}


/// root -> inner -> (leafA, leafB), and root -> leafC: the small hand-built
/// tree both `doir.systems` and `doir.dynamic_systems` walk in their tests.
///
/// Ids are allocated children-first, so it also satisfies the contiguous-id
/// invariant `sorted` relies on.
struct Tree {
	Module mod;
	EntityId leafA, leafB, inner, leafC, root;
}

void link(ref Module mod, EntityId block, EntityId child) @trusted {
	auto related = &getComponent!Block(mod, block).related;
	fp.dynarray.pushBack(*related, child);
}

Tree makeTree() {
	Tree t;
	t.mod = createModule();
	t.leafA = addEntity(t.mod);
	t.leafB = addEntity(t.mod);
	t.inner = addEntity(t.mod);
	addComponent!Block(t.mod, t.inner);
	t.leafC = addEntity(t.mod);
	t.root = addEntity(t.mod);
	addComponent!Block(t.mod, t.root);

	link(t.mod, t.inner, t.leafA);
	link(t.mod, t.inner, t.leafB);
	link(t.mod, t.root, t.inner);
	link(t.mod, t.root, t.leafC);
	return t;
}
