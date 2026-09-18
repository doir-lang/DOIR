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

@nogc nothrow:


private void annotateAt(ref Module mod, ref Diagnostic diag, EntityId entity, const(char)[] name, const(char)[] message) @trusted {
	auto location = findSourceLocation(mod, entity);

	Diagnostic.Annotation annotation;
	annotation.message = text(DoirAnsi.info, name, Ansi.reset, message);
	immutable start = findSlices(mod.source[location.startByte .. location.endByte], name, 0);
	if (start != size_t.max)
		location.startByte += start;
	annotation.position = location.start(mod.source);
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

		auto diag = &pushDiagnostic(DiagnosticType.FailedToResolveLookup,
			findSourceLocation(mod, e), mod.source, workingFileOr(mod, invalidFileName));
		annotateAt(mod, *diag, e, name.view, " appears to have been redefined");

		// NOTE: the C++ loop body reads `entities[1]` rather than
		// `entities[i]`, so every "also defined here" annotation points at the
		// *first* reuse regardless of how many there are. Kept as-is.
		// TODO: What happens if the uses are in different files?
		foreach (_; 0 .. reuseCount)
			annotateAt(mod, *diag, firstReuse, name.view, " also defined here");

		valid = false;
	}

	return valid;
}
