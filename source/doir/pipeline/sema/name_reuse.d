/// `sema.validate.nameReuse`: reports two declarations sharing a name inside
/// one block. Ported from sema/name_reuse.hpp.
module doir.pipeline.sema.name_reuse;

import diagnose.diagnostics : Ansi, Diagnostic, pushAnnotation;
import ecrs.storage : EntityId;

import fp.dynarray : daLength = length;
import fp.string : findSlices;

import doir.diagnostics;
import doir.interface_;
import doir.module_;
import doir.string_helpers : text;

@nogc nothrow:


private void annotateAt(ref Module mod, ref Diagnostic diag, EntityId entity, const(char)[] name, const(char)[] message) @trusted {
	auto location = findSourceLocation(mod, entity);
	auto source = sourceOf(mod, location);

	Diagnostic.Annotation annotation;
	annotation.message = text(DoirAnsi.info, name, Ansi.reset, message);
	immutable start = findSlices(spanOf(source, location), name, 0);
	if (start != size_t.max)
		location.startByte += start;
	annotation.position = location.start(source);
	// The two declarations can sit in different files once one of them came in
	// through an `early_include`; the printer pulls the annotated line out of
	// `file` when it names one (answering the TODO below).
	if (location.file != diag.location.file) annotation.file = location.file;
	pushAnnotation(diag, annotation);
}

bool nameReuse(ref Module mod, EntityId subtree) @trusted {
	if (!hasComponent!Block(mod, subtree)) return true;

	auto block = &getComponent!Block(mod, subtree);
	immutable count = daLength(block.related);
	if (count == 0) return true;

	bool valid = true;

	// The C++ bucketed the names into an unordered_map first; walking the
	// block in order and reporting at each name's *first* occurrence gives
	// the same findings in a deterministic order.
	foreach (i; 0 .. count) {
		immutable e = block.related[i];
		if (!hasComponent!Name(mod, e)) continue;
		const name = getComponent!Name(mod, e).value;

		bool isFirst = true;
		foreach (j; 0 .. i) {
			immutable prev = block.related[j];
			if (hasComponent!Name(mod, prev) && getComponent!Name(mod, prev).value == name) {
				isFirst = false;
				break;
			}
		}
		if (!isFirst) continue;

		// Collect the reuses (there is at least one for us to report).
		size_t reuseCount = 0;
		EntityId firstReuse = 0;
		foreach (j; i + 1 .. count) {
			immutable other = block.related[j];
			if (hasComponent!Name(mod, other) && getComponent!Name(mod, other).value == name) {
				if (reuseCount == 0) firstReuse = other;
				++reuseCount;
			}
		}
		if (reuseCount == 0) continue;

		auto location = findSourceLocation(mod, e);
		auto diag = &pushDiagnostic(DiagnosticType.FailedToResolveLookup,
			location, sourceOf(mod, location), location.file);
		annotateAt(mod, *diag, e, name.view, " appears to have been redefined");

		// NOTE: the C++ loop body reads `entities[1]` rather than
		// `entities[i]`, so every "also defined here" annotation points at the
		// *first* reuse regardless of how many there are. Kept as-is.
		foreach (_; 0 .. reuseCount)
			annotateAt(mod, *diag, firstReuse, name.view, " also defined here");

		valid = false;
	}

	return valid;
}


// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest) {
	import tests.pipeline_helper;
}

unittest { // two declarations sharing a name in one block are reported
	auto r = compile("x : compiler.byte = 1\nx : compiler.byte = 2\n");
	scope(exit) freeModule(r.mod);
	assert(!r.ok);
	assert(diagnostics().hasErrors());
	diagnostics().clear();
}

unittest { // ...and every reuse after the first is annotated, not just one
	auto r = compile(
		"x : compiler.byte = 1\nx : compiler.byte = 2\nx : compiler.byte = 3\n");
	scope(exit) freeModule(r.mod);
	assert(!r.ok);
	assert(diagnostics().hasErrors());
	diagnostics().clear();
}

unittest { // the same name in *different* blocks is fine
	auto r = compile(
		"export a : namespace = {\n\tx : compiler.byte = 1\n}\n"
		~ "export b : namespace = {\n\tx : compiler.byte = 2\n}\n");
	scope(exit) freeModule(r.mod);
	assert(r.ok);
}

unittest { // an entity that is not a block, and an empty one, are skipped
	auto f = makeModuleWithBuiltins();
	scope(exit) freeModule(f.mod);
	diagnostics().clear();

	immutable byte_ = resolveLookupName(f.mod, internIn(f.mod, "compiler.byte"), f.root);
	assert(nameReuse(f.mod, byte_)); // not a block

	immutable empty = addEntity(f.mod);
	addComponent!Block(f.mod, empty);
	assert(nameReuse(f.mod, empty)); // a block with nothing in it
	assert(!diagnostics().hasErrors());
	diagnostics().clear();
}
