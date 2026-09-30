/// `canonicalize.mergeNamespaces`: folds namespaces of the same name declared
/// in one block into the first of them. No C++ predecessor - the C++ compiler
/// never reopened a namespace.
///
/// `early_include` is what makes this necessary: two included files that both
/// declare `std : namespace` splice two `std` entities into the same block, and
/// `findQualifiedScope` returns the first one it finds by name, so every member
/// of the second becomes unreachable. Merging is what makes the two spellings
/// one namespace.
///
/// Types are deliberately left alone. An aggregate is qualifiable through the
/// same path, but two `type = { ... }` declarations of one name are a
/// redefinition rather than two halves of one type - `sema.nameReuse` is what
/// answers those - and silently unioning their fields would invent a layout
/// neither declaration asked for.
module doir.pipeline.canon.merge_namespaces;

import ecrs.storage : EntityId, invalidEntity;

static import fp.dynarray;
import fp.dynarray : daLength = length;

import doir.interface_;
import doir.module_;

@nogc nothrow:


/// A namespace, and not an aggregate wearing the same hat.
private bool mergeable(ref Module mod, EntityId e) @trusted {
	if (!hasComponent!Name(mod, e)) return false;
	if (!hasComponent!Block(mod, e)) return false;
	if (hasComponent!TypeDefinition(mod, e)) return false;
	return flagsSet(mod, e, Flags.Namespace);
}

/// Moves `from`'s declarations onto the end of `into`'s block and reparents
/// them. Order within each half is kept, so a member still follows the
/// declarations it was written after.
private void mergeInto(ref Module mod, EntityId into, EntityId from) @trusted {
	// A `BlockBuilder` is a plain cursor over an existing block, so these two
	// are free and need no `end()`.
	auto dest = BlockBuilder(into, &mod);
	auto src = BlockBuilder(from, &mod);
	moveExisting(dest, src);

	// An `export` on either spelling exports the merged namespace; D-ExportNS
	// reads the flag off one entity and there is only one left.
	if (hasComponent!Flags(mod, from))
		getOrAddComponent!Flags(mod, into).flags |= getComponent!Flags(mod, from).flags;
}

bool mergeNamespaces(ref Module mod, EntityId subtree) @trusted {
	if (!hasComponent!Block(mod, subtree)) return true;

	// Collected before anything is edited: `mergeInto` touches `Parent` and
	// `Flags`, and unlinking shifts the very indices the scan is walking.
	EntityId* absorbed = null;
	EntityId* absorbedBy = null;
	scope(exit) {
		if (absorbed !is null) fp.dynarray.free(absorbed);
		if (absorbedBy !is null) fp.dynarray.free(absorbedBy);
	}

	{
		auto related = &getComponent!Block(mod, subtree).related;
		immutable count = daLength(*related);
		foreach (i; 0 .. count) {
			immutable into = (*related)[i];
			if (!mergeable(mod, into)) continue;

			// The first declaration of the name absorbs; a later one is a
			// donor, and must not also collect donors of its own.
			bool isDonor = false;
			foreach (k; 0 .. daLength(absorbed))
				if (absorbed[k] == into) { isDonor = true; break; }
			if (isDonor) continue;

			const(char)[] name = getComponent!Name(mod, into).value.view;
			foreach (j; i + 1 .. count) {
				immutable from = (*related)[j];
				if (!mergeable(mod, from)) continue;
				if (getComponent!Name(mod, from).value.view != name) continue;
				fp.dynarray.pushBack(absorbed, from);
				fp.dynarray.pushBack(absorbedBy, into);
			}
		}
	}

	immutable merges = daLength(absorbed);
	if (merges == 0) return true;

	foreach (k; 0 .. merges)
		mergeInto(mod, absorbedBy[k], absorbed[k]);

	// Unlinked last, and back to front, so no surviving index moves under the
	// loop. The emptied entity stays in the store; only the block stops listing
	// it, which is all `stripFreestandingBlocks` does to a dead block too.
	auto related = &getComponent!Block(mod, subtree).related;
	for (size_t i = daLength(*related); i-- > 0;)
		foreach (k; 0 .. merges)
			if ((*related)[i] == absorbed[k]) { fp.dynarray.removeAt(*related, i); break; }

	return true;
}


// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest) {
	import doir.diagnostics;
	import tests.pipeline_helper;
}

unittest { // two spellings of one namespace, and a member of each reachable
	auto r = compile(
		"ns : namespace = {\n"
		~ "\texport a : compiler.byte = 1\n"
		~ "}\n"
		~ "ns : namespace = {\n"
		~ "\texport b : compiler.byte = 2\n"
		~ "}\n"
		// Consumed by a call rather than copied out: a bare `x : T = ns.a` is
		// what V-NoImplicitCopy rejects, which would fail the compile for a
		// reason that has nothing to do with resolution.
		~ "x : compiler.byte = compiler.emit(ns.a)\n"
		~ "y : compiler.byte = compiler.emit(ns.b)\n"
	);
	scope(exit) freeModule(r.mod);
	assert(r.ok);
	assert(find(r.mod, r.root, "ns.a") != invalidEntity);
	assert(find(r.mod, r.root, "ns.b") != invalidEntity);
}

unittest { // ...and one `ns` is left listed, carrying both halves
	auto r = compile(
		"ns : namespace = {\n\texport a : compiler.byte = 1\n}\n"
		~ "ns : namespace = {\n\texport b : compiler.byte = 2\n}\n"
		~ "x : compiler.byte = compiler.emit(ns.a)\n"
		~ "y : compiler.byte = compiler.emit(ns.b)\n"
	);
	scope(exit) freeModule(r.mod);
	assert(r.ok);

	size_t named = 0;
	auto related = &getComponent!Block(r.mod, r.root).related;
	foreach (i; 0 .. daLength(*related)) {
		immutable e = (*related)[i];
		if (hasComponent!Name(r.mod, e) && getComponent!Name(r.mod, e).value.view == "ns") ++named;
	}
	assert(named == 1);
}

unittest {
	// Two aggregates of one name are a redefinition, not two halves of a type,
	// so the pass leaves them for `sema.nameReuse` to reject rather than
	// unioning their fields.
	auto r = compile(
		"t : type = {\n\tx : compiler.byte\n}\n"
		~ "t : type = {\n\ty : compiler.byte\n}\n"
	);
	scope(exit) freeModule(r.mod);
	assert(!r.ok);
	assert(diagnostics().hasErrors());
	diagnostics().clear();
}

unittest { // nothing to merge, so running the pass again changes nothing
	auto r = compile(
		"ns : namespace = {\n\texport a : compiler.byte = 1\n}\n"
		~ "x : compiler.byte = compiler.emit(ns.a)\n"
	);
	scope(exit) freeModule(r.mod);
	assert(r.ok);

	immutable a = find(r.mod, r.root, "ns.a");
	assert(a != invalidEntity);
	assert(mergeNamespaces(r.mod, r.root));
	assert(find(r.mod, r.root, "ns.a") == a);
}
