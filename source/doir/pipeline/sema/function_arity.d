/// `sema.validate.functionArity`: checks a call passes as many arguments as
/// its function type declares. Ported from sema/function_arity.hpp.
module doir.pipeline.sema.function_arity;

import diagnose.diagnostics : Ansi, Diagnostic, pushAnnotation;
import ecrs.storage : EntityId;

import fp.dynarray : daLength = length;

import doir.diagnostics;
import doir.interface_;
import doir.module_;

@nogc nothrow:


bool functionArity(ref Module mod, EntityId subtree) @trusted {
	if (!hasComponent!Call(mod, subtree)) return true;

	immutable decl = resolveAlias(mod, getComponent!Call(mod, subtree).related[0]);
	immutable ft = resolveTypeModifications(mod, getComponent!TypeOf(mod, decl).related[0]);

	immutable callCount = daLength(getComponent!FunctionInputs(mod, subtree).related);
	immutable declCount = daLength(getComponent!FunctionInputs(mod, ft).related);

	if (callCount != declCount) {
		auto location = findSourceLocation(mod, subtree);
		auto diag = &pushDiagnostic(DiagnosticType.InvalidFunctionCall, location, mod.source,
			workingFileOr(mod, invalidFileName));

		Diagnostic.Annotation annotation;
		annotation.message = text("Number of function parameters ", DoirAnsi.info, callCount, Ansi.reset,
			" differs from expected number ", DoirAnsi.info, declCount, Ansi.reset);

		bool found;
		auto range = parseParameterRange(mod.source[location.startByte .. location.endByte],
			callCount - 1, found);
		if (found)
			location.startByte += (range.start + range.end) / 2;
		annotation.position = location.start(mod.source);
		pushAnnotation(*diag, annotation);
		return false;
	}
	return true;
}


// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
// Ported from tests/spec_syntax.test.cpp.

version (unittest) {
	import ecrs.storage : invalidEntity;
	import tests.pipeline_helper;
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
