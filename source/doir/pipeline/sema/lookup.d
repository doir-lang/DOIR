/// The lookup-resolution pass and its validation half. Ported from
/// sema/lookup.cpp.
module doir.pipeline.sema.lookup;

import diagnose.diagnostics : Ansi, Diagnostic, pushAnnotation;
import ecrs.storage : EntityId, invalidEntity;

static import fp.dynarray;
import fp.dynarray : daLength = length;
import fp.string : findSlices;

import doir.diagnostics;
import doir.interface_;
import doir.module_;

@nogc nothrow:


/// Resolves every unresolved reference on `e` that can be resolved yet.
/// With `typesOnly`, aliases and non-type-modifier call arguments are left
/// for the second pass.
bool resolveLookups(ref Module mod, EntityId e, bool typesOnly) @trusted {
	if (hasComponent!LookupLookup(mod, e)) {
		auto lookup = &getComponent!LookupLookup(mod, e);
		resolveLookup(mod, lookup.lookup, e, true);
	}
	if (hasComponent!LookupFunctionReturnType(mod, e)) {
		auto lookup = &getComponent!LookupFunctionReturnType(mod, e);
		resolveLookup(mod, lookup.lookup, e); // Not strict so that returns can find their parameters
	}
	if (hasComponent!LookupCall(mod, e)) {
		auto lookup = &getComponent!LookupCall(mod, e);
		resolveLookup(mod, lookup.lookup, e, true);
	}
	if (hasComponent!LookupFunctionInputs(mod, e)) {
		bool shouldResolve = hasComponent!TypeDefinition(mod, e) || !typesOnly;
		if (!shouldResolve && (hasComponent!Call(mod, e) || hasComponent!LookupCall(mod, e))) {
			auto lookup = callOf(mod, e);
			if (lookup.resolved()) {
				immutable func = lookup.entity();
				foreach (m; typeModifiers(mod, e))
					if (m == func) { shouldResolve = true; break; }
			}
		}

		if (shouldResolve) {
			auto lookups = &getComponent!LookupFunctionInputs(mod, e);
			foreach (i; 0 .. length(*lookups))
				resolveLookup(mod, (*lookups)[i], e); // Not strict so that parameters can find their neighbors
		}
	}
	if (!typesOnly && hasComponent!LookupAlias(mod, e)) {
		auto lookup = &getComponent!LookupAlias(mod, e);
		resolveLookup(mod, lookup.lookup, e, true);
	}
	if (hasComponent!LookupTypeOf(mod, e)) {
		auto lookup = &getComponent!LookupTypeOf(mod, e);
		resolveLookup(mod, lookup.lookup, e, true);
	}

	return true;
}

private void unresolvedDiagnostic(ref Module mod, EntityId e, const(char)[] what, const(char)[] name) @trusted {
	auto location = findDetailedSourceLocation(mod, e);
	auto diag = &pushDiagnostic(DiagnosticType.FailedToResolveLookup,
		location, sourceOf(mod, location), location.file);

	Diagnostic.Annotation annotation;
	annotation.message = text(what, DoirAnsi.info, name, Ansi.reset, " appears to not exist");
	annotation.position = diag.location.start;
	pushAnnotation(*diag, annotation);
}

/// Promotes every resolved lookup to its resolved component, and reports the
/// ones still unresolved.
bool lookupsResolved(ref Module mod, EntityId e) @trusted {
	bool valid = true;

	if (hasComponent!LookupLookup(mod, e)) {
		auto lookup = &getComponent!LookupLookup(mod, e);
		if (!lookup.lookup.resolved()) {
			unresolvedDiagnostic(mod, e, "Object ", lookup.lookup.name().view);
			valid = false;
		}
	}
	if (hasComponent!LookupFunctionReturnType(mod, e)) {
		auto lookup = getComponent!LookupFunctionReturnType(mod, e).lookup;
		if (lookup.resolved()) {
			addComponent!FunctionReturnType(mod, e).related[0] = lookup.entity();
			removeComponent!LookupFunctionReturnType(mod, e);
		} else {
			unresolvedDiagnostic(mod, e, "Type ", lookup.name().view);
			valid = false;
		}
	}
	if (hasComponent!LookupFunctionInputs(mod, e)) {
		{
			auto lookups = &getComponent!LookupFunctionInputs(mod, e);
			foreach (i; 0 .. length(*lookups))
				if (!(*lookups)[i].resolved()) {
					unresolvedDiagnostic(mod, e, "Function argument ", (*lookups)[i].name().view);
					valid = false;
				}
		}

		if (valid) {
			auto old = &getComponent!LookupFunctionInputs(mod, e);
			immutable count = length(*old);
			EntityId* resolved = null;
			scope(exit) if (resolved !is null) fp.dynarray.free(resolved);
			foreach (i; 0 .. count)
				fp.dynarray.pushBack(resolved, (*old)[i].entity());

			auto new_ = &addComponent!FunctionInputs(mod, e);
			foreach (i; 0 .. count)
				fp.dynarray.pushBack(new_.related, resolved[i]);
			removeComponent!LookupFunctionInputs(mod, e);
		}
	}
	if (hasComponent!LookupAlias(mod, e)) {
		auto lookup = getComponent!LookupAlias(mod, e).lookup;
		if (lookup.resolved()) {
			addComponent!Alias(mod, e).related[0] = lookup.entity();
			removeComponent!LookupAlias(mod, e);
		} else {
			unresolvedDiagnostic(mod, e, "Alias ", lookup.name().view);
			valid = false;
		}
	}
	if (hasComponent!LookupTypeOf(mod, e)) {
		auto lookup = getComponent!LookupTypeOf(mod, e).lookup;
		if (lookup.resolved()) {
			addComponent!TypeOf(mod, e).related[0] = lookup.entity();
			removeComponent!LookupTypeOf(mod, e);
		} else {
			unresolvedDiagnostic(mod, e, "Type ", lookup.name().view);
			valid = false;
		}
	}
	if (hasComponent!LookupCall(mod, e)) {
		auto lookup = getComponent!LookupCall(mod, e).lookup;
		if (lookup.resolved()) {
			addComponent!Call(mod, e).related[0] = lookup.entity();
			removeComponent!LookupCall(mod, e);
		} else {
			auto location = findSourceLocation(mod, e);
			auto source = sourceOf(mod, location);
			auto diag = &pushDiagnostic(DiagnosticType.FailedToResolveLookup, location, source,
				location.file);

			Diagnostic.Annotation annotation;
			annotation.message = text("Function ", DoirAnsi.info, lookup.name().view, Ansi.reset,
				" appears to not exist");
			immutable start = findSlices(spanOf(source, location), lookup.name().view, 0);
			if (start != size_t.max)
				location.startByte += start;
			annotation.position = location.start(source);
			pushAnnotation(*diag, annotation);
			valid = false;
		}
	}

	return valid;
}


// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest) {
	import tests.pipeline_helper;
}

unittest { // each kind of name that cannot be resolved is reported as such
	static immutable string[4] sources = [
		"x : nope = 1\n",                                   // Type
		"x : alias = nope\n",                               // Alias
		"n : compiler.byte = 1\nx : compiler.byte = nope(n)\n", // Function
		"n : compiler.byte = 1\nx : compiler.byte = compiler.emit(nope)\n", // Function argument
	];
	foreach (source; sources) {
		auto r = compile(source);
		scope(exit) freeModule(r.mod);
		assert(!r.ok);
		assert(diagnostics().hasErrors());
		diagnostics().clear();
	}
}

unittest { // ...and an unresolvable function return type too
	auto r = compile("f : (a: compiler.byte) -> nope\n");
	scope(exit) freeModule(r.mod);
	assert(!r.ok);
	assert(diagnostics().hasErrors());
	diagnostics().clear();
}

unittest {
	// `LookupLookup` is a plain "this entity refers to that name" reference.
	// Nothing in the parser produces one, so both halves of the pass are
	// driven directly.
	//
	// The reference is resolved *strictly*, which searches forward from the
	// referring entity for the block containing it - an invariant
	// `canonicalize.sort` establishes - so the module is sorted first, the way
	// it is by the time the real pass runs.
	import doir.pipeline.sema.sort : sort;

	auto f = makeModuleWithBuiltins();
	scope(exit) freeModule(f.mod);
	diagnostics().clear();

	auto block = BlockBuilder(f.root, &f.mod);
	immutable byte_ = resolveLookupName(f.mod, internIn(f.mod, "compiler.byte"), f.root);
	pushNumber(block, internIn(f.mod, "target"), byte_, 1);
	pushCommon(f.mod, f.root, internIn(f.mod, "user"));
	pushCommon(f.mod, f.root, internIn(f.mod, "dangling"));

	immutable root = sort(f.mod, f.root);
	immutable target = resolveLookupName(f.mod, internIn(f.mod, "target"), root);
	immutable user = resolveLookupName(f.mod, internIn(f.mod, "user"), root);
	immutable dangling = resolveLookupName(f.mod, internIn(f.mod, "dangling"), root);
	assert(target != invalidEntity && user != invalidEntity && dangling != invalidEntity);

	addComponent!LookupLookup(f.mod, user).lookup = Lookup(internIn(f.mod, "target"));
	assert(resolveLookups(f.mod, user, false));
	assert(getComponent!LookupLookup(f.mod, user).lookup.resolved());
	assert(getComponent!LookupLookup(f.mod, user).lookup.entity() == target);
	assert(lookupsResolved(f.mod, user));
	assert(!diagnostics().hasErrors());

	// One that names nothing is reported instead.
	addComponent!LookupLookup(f.mod, dangling).lookup = Lookup(internIn(f.mod, "nope"));
	assert(resolveLookups(f.mod, dangling, false));
	assert(!lookupsResolved(f.mod, dangling));
	assert(diagnostics().hasErrors());
	diagnostics().clear();
}
