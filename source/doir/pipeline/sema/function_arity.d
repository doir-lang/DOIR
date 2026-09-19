/// `sema.validate.functionArity`: checks a call passes as many arguments as
/// its function type declares. Ported from sema/function_arity.hpp.
module doir.pipeline.sema.function_arity;

import diagnose.diagnostics : Ansi, Diagnostic, pushAnnotation;
import ecrs.storage : EntityId, invalidEntity;

import fp.dynarray : daLength = length;

import doir.diagnostics;
import doir.interface_;
import doir.module_;

@nogc nothrow:


bool functionArity(ref Module mod, EntityId subtree) @trusted {
	if (!hasComponent!Call(mod, subtree)) return true;

	immutable decl = resolveAlias(mod, getComponent!Call(mod, subtree).related[0]);

	// Whatever the call resolved to has to actually be callable. A type
	// definition (`x : type = (a: T) -> U`, then `y : x = x()`) has no `TypeOf`
	// at all, and a value of a non-function type has one that declares no
	// parameters - both used to assert deep inside sema instead of being
	// reported here.
	immutable ft = hasComponent!TypeOf(mod, decl)
		? resolveTypeModifications(mod, getComponent!TypeOf(mod, decl).related[0])
		: invalidEntity;
	if (ft == invalidEntity || !hasComponent!FunctionInputs(mod, ft)) {
		notAFunction(mod, subtree, decl);
		return false;
	}

	immutable callCount = daLength(getComponent!FunctionInputs(mod, subtree).related);
	immutable declCount = daLength(getComponent!FunctionInputs(mod, ft).related);

	if (callCount != declCount) {
		auto location = findSourceLocation(mod, subtree);
		auto source = sourceOf(mod, location);
		auto diag = &pushDiagnostic(DiagnosticType.InvalidFunctionCall, location, source,
			location.file);

		Diagnostic.Annotation annotation;
		annotation.message = text("Number of function parameters ", DoirAnsi.info, callCount, Ansi.reset,
			" differs from expected number ", DoirAnsi.info, declCount, Ansi.reset);

		bool found;
		auto range = parseParameterRange(spanOf(source, location),
			callCount > 0 ? callCount - 1 : 0, found);
		if (found)
			location.startByte += (range.start + range.end) / 2;
		annotation.position = location.start(source);
		pushAnnotation(*diag, annotation);
		return false;
	}
	return true;
}


/// `<name> is not a function` - what a call whose target has no function type
/// resolved to.
private void notAFunction(ref Module mod, EntityId subtree, EntityId decl) @trusted {
	auto location = findSourceLocation(mod, subtree);
	auto diag = &pushDiagnostic(DiagnosticType.InvalidFunctionCall,
		location, sourceOf(mod, location), location.file);

	Diagnostic.Annotation annotation;
	if (hasComponent!Name(mod, decl))
		annotation.message = text(DoirAnsi.func, getComponent!Name(mod, decl).value.view,
			Ansi.reset, " is not a function and cannot be called");
	else
		annotation.message = text("Entity ", DoirAnsi.info, cast(size_t) decl, Ansi.reset,
			" is not a function and cannot be called");
	annotation.position = diag.location.start;
	pushAnnotation(*diag, annotation);
}


// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
// Ported from tests/spec_syntax.test.cpp.

version (unittest) {
	import tests.pipeline_helper;
}

unittest {
	// The call target has to actually be callable. `x` here is a *type*
	// definition, which carries no `TypeOf` at all, so `getComponent!TypeOf` on
	// it asserted - first inside `sema.bubbleComptime`, and then here. Both now
	// leave it to this pass to report.
	auto r = compile(
		"x : type = (a: compiler.byte) -> compiler.byte\n"
		~ "y : x = x()\n");
	scope(exit) freeModule(r.mod);
	assert(!r.ok);
	assert(diagnostics().hasErrors());
	diagnostics().clear();
}

unittest { // a genuine arity mismatch is still reported, and with no arguments at all
	auto r = compile("%1 : compiler.byte = compiler.emit()\n");
	scope(exit) freeModule(r.mod);
	assert(!r.ok);
	assert(diagnostics().hasErrors());
	diagnostics().clear();
}

unittest {
	// Calling a builtin function through an alias survives arity checking and
	// comptime bubbling. `functionArity` immediately did `getComponent!TypeOf`
	// on the call target, and an alias entity has no TypeOf component at all -
	// so calling *any* function through an alias was a guaranteed crash.
	auto r = compile(
		"begin_alloc_alias : alias = compiler.assembler.begin_register_allocation\n"
		~ "%1 : compiler.assembler.register = begin_alloc_alias()\n");
	scope(exit) freeModule(r.mod);
	assert(r.ok);
	assert(find(r.mod, r.root, "%1") != invalidEntity);
}
