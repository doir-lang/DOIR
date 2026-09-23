/// `sema.typeCheck`: the post-comptime half of the type system - every
/// unsolved variable is an error now, and every call has to agree with what its
/// function type declares, in its arguments (D-Deduce) and in the register its
/// result is assigned to (S-Assign).
///
/// It is scheduled by the *backend*, at the front of `mizu.schedule`, not by
/// `canonicalizeSchedule`. That is the same call the schedule already makes for
/// `nameReuse` and `functionArity`: what counts as a type mismatch is something
/// a backend should be able to say differently, and a pass the compiler runs
/// before handing over is one it has already decided for everyone. A backend
/// that wants a laxer rule drops this from its schedule and puts its own in.
///
/// Running after comptime is what M-Freeze licenses. A modifier is a comptime
/// call, so once the comptime fixpoint has settled no flag is added or removed
/// again and every type has exactly one answer; checking earlier would have to
/// ask what `Phi(t)` was at each use site's lexical position instead (P2).
/// The two things that genuinely cannot wait - overload selection and C-Valid -
/// are consumed *during* comptime and are checked there.
module doir.pipeline.sema.type_check;

import diagnose.diagnostics : Ansi, Diagnostic, pushAnnotation;
import ecrs.storage : EntityId, invalidEntity;

static import fp.dynarray;
import fp.dynarray : daLength = length;

import doir.diagnostics;
import doir.interface_;
import doir.module_;
import doir.string_helpers : text;

import doir.pipeline.canon.sort : loweringThrowawayBlock;
import doir.pipeline.sema.type_variables : isTypeVariable, typeIsUnknown;

@nogc nothrow:


// ---------------------------------------------------------------------------
// Type identity
// ---------------------------------------------------------------------------

/// Whether `a` and `b` are the same type, per S-Struct: same size, same
/// alignment, same uniqueness discriminator.
///
/// Comparison is deliberately *one-sided about ignorance*. Two types agree if
/// they are the same entity, or if both are definitions that match on
/// $⟨"size", "alignment", "unique"⟩$; anything this cannot read - a type that
/// is still an unfolded call, a function type, a variable - is reported as
/// agreeing rather than as a mismatch. A checker that guesses in the other
/// direction turns every gap in the rest of the compiler into a diagnostic
/// against the user's program.
///
/// Which makes this only as strong as what has been folded before it runs:
/// every builtin type is a `compiler.base_type` call until something folds it,
/// so `opt.foldBaseTypes` is scheduled ahead of this pass (A-Ident).
bool typesAgree(ref Module mod, EntityId a, EntityId b) @trusted {
	a = resolveAlias(mod, a);
	b = resolveAlias(mod, b);
	if (a == b) return true;
	if (a == invalidEntity || b == invalidEntity) return true;

	// A pointer agrees with a pointer to an agreeing type and the same bound.
	// `compiler.pointer` is peeled here rather than by
	// `resolveTypeModifications`, which would peel it off *one* side and call a
	// pointer the same type as what it points at.
	if (hasComponent!Pointer(mod, a) || hasComponent!Pointer(mod, b)) {
		if (!(hasComponent!Pointer(mod, a) && hasComponent!Pointer(mod, b))) return true;
		auto pa = &getComponent!Pointer(mod, a);
		auto pb = &getComponent!Pointer(mod, b);
		if (pa.size != pb.size) return false;
		return typesAgree(mod, pa.related[0], pb.related[0]);
	}

	if (!(hasComponent!TypeDefinition(mod, a) && hasComponent!TypeDefinition(mod, b)))
		return true;

	auto da = &getComponent!TypeDefinition(mod, a);
	auto db = &getComponent!TypeDefinition(mod, b);
	return da.size == db.size && da.alignment == db.alignment && da.unique == db.unique;
}

/// How to name a type in a diagnostic, or null when it has no name to give.
private const(char)[] typeName(ref Module mod, EntityId type) {
	type = resolveAlias(mod, type);
	if (hasComponent!Name(mod, type)) return getComponent!Name(mod, type).value.view;
	return null;
}


// ---------------------------------------------------------------------------
// The pass
// ---------------------------------------------------------------------------

/// A hole nothing ever filled. By the time this runs there is no round left to
/// fill it in, so it is the author's to resolve.
private void unsolvedVariable(ref Module mod, EntityId e) @trusted {
	auto location = findSourceLocation(mod, e);
	auto diag = &pushDiagnostic(DiagnosticType.InvalidType, location,
		sourceOf(mod, location), location.file);

	Diagnostic.Annotation annotation;
	annotation.message = hasComponent!Name(mod, e)
		? text("Could not deduce the type of ", DoirAnsi.info,
			getComponent!Name(mod, e).value.view, Ansi.reset)
		: text("Could not deduce the type of entity ", DoirAnsi.info, cast(size_t) e, Ansi.reset);
	annotation.position = diag.location.start;
	pushAnnotation(*diag, annotation);
}

/// Every `deduced` parameter of a call the unifier could not solve, named.
private void undeducedParameters(ref Module mod, EntityId call, EntityId ft) @trusted {
	auto location = findSourceLocation(mod, call);
	auto names = hasComponent!FunctionParameterNames(mod, ft)
		? slice(getComponent!FunctionParameterNames(mod, ft))
		: null;

	auto params = &getComponent!FunctionInputs(mod, ft);
	foreach (position; 0 .. daLength(params.related)) {
		if (!isDeducedParameter(mod, ft, position)) continue;

		auto diag = &pushDiagnostic(DiagnosticType.InvalidType, location,
			sourceOf(mod, location), location.file);

		Diagnostic.Annotation annotation;
		annotation.message = position < names.length
			? text("Could not deduce ", DoirAnsi.type, names[position].view, Ansi.reset,
				" from this call")
			: text("Could not deduce parameter ", DoirAnsi.info, position, Ansi.reset,
				" from this call");
		annotation.position = diag.location.start;
		pushAnnotation(*diag, annotation);
	}
}

private void argumentMismatch(ref Module mod, EntityId call, size_t index,
	EntityId got, EntityId expected) @trusted
{
	auto location = findSourceLocation(mod, call);
	auto diag = &pushDiagnostic(DiagnosticType.InvalidType, location,
		sourceOf(mod, location), location.file);

	auto gotName = typeName(mod, got);
	auto expectedName = typeName(mod, expected);

	Diagnostic.Annotation annotation;
	if (gotName !is null && expectedName !is null)
		annotation.message = text("Argument ", DoirAnsi.info, index, Ansi.reset,
			" has type ", DoirAnsi.type, gotName, Ansi.reset,
			", but ", DoirAnsi.type, expectedName, Ansi.reset, " was expected");
	else
		annotation.message = text("Argument ", DoirAnsi.info, index, Ansi.reset,
			" has the wrong type");
	annotation.position = diag.location.start;
	pushAnnotation(*diag, annotation);
}

private void returnMismatch(ref Module mod, EntityId call, EntityId declared,
	EntityId returned) @trusted
{
	auto location = findSourceLocation(mod, call);
	auto diag = &pushDiagnostic(DiagnosticType.InvalidType, location,
		sourceOf(mod, location), location.file);

	auto declaredName = typeName(mod, declared);
	auto returnedName = typeName(mod, returned);

	Diagnostic.Annotation annotation;
	if (declaredName !is null && returnedName !is null)
		annotation.message = text("This call returns ", DoirAnsi.type, returnedName, Ansi.reset,
			", but the register it is assigned to is declared ",
			DoirAnsi.type, declaredName, Ansi.reset);
	else
		annotation.message = text("This call does not return the type the register it is "
			~ "assigned to is declared");
	annotation.position = diag.location.start;
	pushAnnotation(*diag, annotation);
}

/// The declared type of `e`, or `invalidEntity` when it has none to declare.
private EntityId declaredType(ref Module mod, EntityId e) {
	e = resolveAlias(mod, e);
	if (!hasComponent!TypeOf(mod, e)) return invalidEntity;
	return getComponent!TypeOf(mod, e).related[0];
}


bool typeCheck(ref Module mod, EntityId subtree) @trusted {
	// Only the program the author wrote. The comptime evaluator lowers each
	// block it builds with this same schedule, and lowering manufactures exactly
	// what this rejects - `opt.inlineFunctions` copies a body in with its
	// parameters replaced by the caller's values, so `execute_if`'s `blk : block`
	// is a `u64` in every copy. `sema.validateComptime` sits out of the backend's
	// schedule entirely for the same reason; this one only sits out the nested
	// runs, which is what lets a backend schedule it at all.
	if (loweringThrowawayBlock()) return true;

	bool valid = true;

	if (hasComponent!TypeVariable(mod, subtree)) {
		// The placeholder `_` itself carries the tag as a marker and is not a
		// hole anybody wrote; it is the thing holes used to resolve to.
		if (!hasComponent!Name(mod, subtree)
			|| getComponent!Name(mod, subtree).value.view != "_")
		{
			unsolvedVariable(mod, subtree);
			valid = false;
		}
	}

	if (!hasComponent!Call(mod, subtree)) return valid;
	if (!hasComponent!FunctionInputs(mod, subtree)) return valid;

	immutable decl = resolveAlias(mod, getComponent!Call(mod, subtree).related[0]);
	immutable ft = hasComponent!TypeOf(mod, decl)
		? resolveTypeModifications(mod, getComponent!TypeOf(mod, decl).related[0])
		: invalidEntity;
	// Not a function, or a function type whose parameters are not resolved yet:
	// `sema.functionArity` owns the first and reports it, and the second has
	// nothing to compare against.
	if (ft == invalidEntity || !hasComponent!FunctionInputs(mod, ft)) return valid;

	auto args = &getComponent!FunctionInputs(mod, subtree);
	auto params = &getComponent!FunctionInputs(mod, ft);

	// A call still short by its `deduced` parameters is one the unifier never
	// solved - every round of the comptime fixpoint has been and gone, so there
	// is nothing left to solve it. Reported here rather than as an arity
	// mismatch because the count is exactly what the author was supposed to
	// write (D-Deduce), and reported *instead* of what is below: the arguments
	// of an unelaborated call do not line up with the parameters, so comparing
	// them pairwise would blame whatever happens to sit at each index.
	immutable deduced = deducedParameterCount(mod, ft);
	if (deduced > 0 && daLength(args.related) + deduced == daLength(params.related)) {
		undeducedParameters(mod, subtree, ft);
		return false;
	}

	// Arity is `functionArity`'s to report; checking the overlap keeps this pass
	// from producing a second diagnostic about the same call.
	auto count = daLength(args.related);
	if (daLength(params.related) < count) count = daLength(params.related);

	foreach (i; 0 .. count) {
		immutable got = declaredType(mod, args.related[i]);
		// `v : T` expects whatever `T` came out as *here* - the argument in
		// `T`'s position, which for a `deduced` parameter is the solution
		// `sema.deduceTypes` fixed from the first argument that reached
		// it. Comparing against the parameter declaration instead would compare
		// against a type that has no layout, which agrees with everything: this
		// is what makes `is_equal(a, b)` an implicit same-type constraint
		// (D-Deduce) rather than a rule nothing enforces.
		immutable expected = typeAtCallSite(mod, subtree, ft, resolveAlias(mod, params.related[i]));
		if (got == invalidEntity || expected == invalidEntity) continue;
		if (typesAgree(mod, got, expected)) continue;

		argumentMismatch(mod, subtree, i, got, expected);
		valid = false;
	}

	// SSA: a declaration is the register the call's result lands in, so what it
	// declares has to be what the call returns. Nothing else in the pipeline
	// asks - `sema.deduceTypes` reads a return type only to fill a `_`, and
	// `canonicalize.materializeFunctionType` copies one onto the call site only
	// when there is none there - so an explicit annotation reaches the backend
	// unexamined, and a wrong one silently retypes the register.
	//
	// Only when the arguments agreed. A `-> T` is solved *from* the arguments
	// (D-Deduce), so reporting it against a call already rejected above would be
	// a second symptom of the one mistake.
	if (valid && !typeIsUnknown(mod, subtree)) {
		immutable declared = declaredType(mod, subtree);
		immutable returned = typeAtCallSite(mod, subtree, ft, resolvedReturnTypeOf(mod, ft));
		if (declared != invalidEntity && returned != invalidEntity
			&& !isTypeVariable(mod, returned) && !typesAgree(mod, declared, returned))
		{
			returnMismatch(mod, subtree, declared, returned);
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

unittest { // a type agrees with itself, and with an alias to itself
	auto f = makeModuleWithBuiltins();
	scope(exit) freeModule(f.mod);

	immutable byte_ = resolveLookupName(f.mod, internIn(f.mod, "compiler.byte"), f.root);
	auto block = BlockBuilder(f.root, &f.mod);
	immutable byteAlias = pushAlias(block, internIn(f.mod, "b"), byte_);

	assert(typesAgree(f.mod, byte_, byte_));
	assert(typesAgree(f.mod, byteAlias, byte_));
}

unittest { // two definitions that differ in layout do not agree
	auto f = makeModuleWithBuiltins();
	scope(exit) freeModule(f.mod);

	auto block = BlockBuilder(f.root, &f.mod);
	immutable small = pushType(block, internIn(f.mod, "small")).end();
	immutable large = pushType(block, internIn(f.mod, "large")).end();
	getComponent!TypeDefinition(f.mod, small).size = 8;
	getComponent!TypeDefinition(f.mod, large).size = 16;

	assert(!typesAgree(f.mod, small, large));

	// ...and agree again once their layouts match, which is S-Struct rather
	// than entity identity.
	getComponent!TypeDefinition(f.mod, large).size = 8;
	assert(typesAgree(f.mod, small, large));
}

unittest { // uniqueness blocks agreement even at identical layout (M-Unique)
	auto f = makeModuleWithBuiltins();
	scope(exit) freeModule(f.mod);

	auto block = BlockBuilder(f.root, &f.mod);
	immutable plain = pushType(block, internIn(f.mod, "plain")).end();
	immutable marked = pushType(block, internIn(f.mod, "marked")).end();
	getComponent!TypeDefinition(f.mod, marked).unique = 1;

	assert(!typesAgree(f.mod, plain, marked));
}

unittest {
	// `type` and `block` are the kinds that are not values, so they have no
	// layout to be compared by and carry reserved discriminators instead
	// (M-Unique). Without them they would be each other's type, and every empty
	// aggregate in the program would be both.
	auto f = makeModuleWithBuiltins();
	scope(exit) freeModule(f.mod);

	immutable type = resolveLookupName(f.mod, internIn(f.mod, "type"), f.root);
	immutable block = resolveLookupName(f.mod, internIn(f.mod, "block"), f.root);
	immutable void_ = resolveLookupName(f.mod, internIn(f.mod, "void"), f.root);
	immutable deduced = resolveLookupName(f.mod, internIn(f.mod, "deduced_type"), f.root);

	assert(!typesAgree(f.mod, type, block));
	assert(!typesAgree(f.mod, type, void_));
	assert(!typesAgree(f.mod, block, void_));

	// `void` is not one of them: it is a value with no bits, so it is the same
	// type as an empty aggregate and S-Struct is what says so.
	auto builder = openRoot(f);
	immutable empty = pushType(builder, internIn(f.mod, "empty")).end();
	assert(typesAgree(f.mod, void_, empty));
	assert(!typesAgree(f.mod, type, empty));
	assert(!typesAgree(f.mod, block, empty));

	// `deduced type` is the exception among the reserved ones, and is the
	// pairing the standard interface depends on: `move`'s `return(%0)`
	// elaborates to `return(T, %0)`, which hands a `T : type` to a parameter
	// declared `deduced type`.
	assert(typesAgree(f.mod, type, deduced));
}

unittest { // a pointer agrees only with a pointer to an agreeing type
	auto f = makeModuleWithBuiltins();
	scope(exit) freeModule(f.mod);

	immutable byte_ = resolveLookupName(f.mod, internIn(f.mod, "compiler.byte"), f.root);
	auto block = BlockBuilder(f.root, &f.mod);
	immutable p1 = pushPointer(block, internIn(f.mod, "p1"), byte_);
	immutable p2 = pushPointer(block, internIn(f.mod, "p2"), byte_);
	immutable arr = pushPointer(block, internIn(f.mod, "arr"), byte_, 4);

	assert(typesAgree(f.mod, p1, p2));
	assert(!typesAgree(f.mod, p1, arr)); // same target, different bound
}

unittest {
	// `v : T` is compared against what `T` came out as *at this call site*, not
	// against the parameter declaration - which has no layout of its own and so
	// agrees with everything. This is the half of D-Deduce that makes
	// `is_equal(a, b)` a same-type constraint: `sema.deduceTypes` fixes
	// `T` to the first argument's type and every later one is checked against
	// it.
	auto r = compile("f : (T: type, v: T) -> T\n");
	scope(exit) freeModule(r.mod);
	assert(r.ok);
	diagnostics().clear();

	auto block = BlockBuilder(r.root, &r.mod);
	immutable small = pushType(block, internIn(r.mod, "small")).end();
	immutable large = pushType(block, internIn(r.mod, "large")).end();
	getComponent!TypeDefinition(r.mod, small).size = 8;
	getComponent!TypeDefinition(r.mod, large).size = 16;

	immutable f = find(r.mod, r.root, "f");
	immutable value = pushNumber(block, internIn(r.mod, "v"), large, 1);

	EntityId[2] wrong = [small, value];
	immutable mismatch = pushCall(block, internIn(r.mod, "bad"), small, f, wrong[]);
	assert(!typeCheck(r.mod, mismatch));
	assert(diagnostics().hasErrors());
	diagnostics().clear();

	// ...and the same call with `T` solved to the type the value actually has
	// is the one that goes through.
	EntityId[2] right = [large, value];
	immutable agreeing = pushCall(block, internIn(r.mod, "good"), large, f, right[]);
	assert(typeCheck(r.mod, agreeing));
	assert(!diagnostics().hasErrors());
}

unittest {
	// SSA: the register a call's result lands in is declared as what the call
	// returns, and nothing else in the pipeline compares the two - a hole reads
	// a return type, and `canonicalize.materializeFunctionType` fills an empty
	// slot, but neither checks one that is already there.
	auto f = makeModuleWithBuiltins();
	scope(exit) freeModule(f.mod);
	diagnostics().clear();

	auto block = BlockBuilder(f.root, &f.mod);
	immutable small = pushType(block, internIn(f.mod, "small")).end();
	immutable large = pushType(block, internIn(f.mod, "large")).end();
	getComponent!TypeDefinition(f.mod, small).size = 8;
	getComponent!TypeDefinition(f.mod, large).size = 16;

	EntityId[0] none;
	immutable ft = pushFunctionType(block, internIn(f.mod, "ft"), none[], cast(EntityId) small, true);
	immutable fn = pushValuelessFunction(block, internIn(f.mod, "fn"), ft);

	immutable mismatch = pushCall(block, internIn(f.mod, "bad"), large, fn, none[]);
	assert(!typeCheck(f.mod, mismatch));
	assert(diagnostics().hasErrors());
	diagnostics().clear();

	immutable agreeing = pushCall(block, internIn(f.mod, "good"), small, fn, none[]);
	assert(typeCheck(f.mod, agreeing));
	assert(!diagnostics().hasErrors());
}

unittest {
	// A `-> T` is read at the call site too (D-Deduce), so what the register is
	// compared against is the argument in `T`'s position rather than the
	// parameter declaration every call through the type shares.
	auto r = compile("f : (T: type, v: T) -> T\n");
	scope(exit) freeModule(r.mod);
	assert(r.ok);
	diagnostics().clear();

	auto block = BlockBuilder(r.root, &r.mod);
	immutable small = pushType(block, internIn(r.mod, "small")).end();
	immutable large = pushType(block, internIn(r.mod, "large")).end();
	getComponent!TypeDefinition(r.mod, small).size = 8;
	getComponent!TypeDefinition(r.mod, large).size = 16;

	immutable f = find(r.mod, r.root, "f");
	immutable value = pushNumber(block, internIn(r.mod, "v"), small, 1);

	// `f(small, v)` returns `small`, so a register declared `large` is wrong...
	EntityId[2] arguments = [small, value];
	immutable mismatch = pushCall(block, internIn(r.mod, "bad"), large, f, arguments[]);
	assert(!typeCheck(r.mod, mismatch));
	assert(diagnostics().hasErrors());
	diagnostics().clear();

	// ...and one declared `small` is what the call actually hands back.
	immutable agreeing = pushCall(block, internIn(r.mod, "good"), small, f, arguments[]);
	assert(typeCheck(r.mod, agreeing));
	assert(!diagnostics().hasErrors());
}

unittest { // an unsolved variable is reported
	auto f = makeModuleWithBuiltins();
	scope(exit) freeModule(f.mod);
	diagnostics().clear();

	immutable e = pushCommon(f.mod, f.root, internIn(f.mod, "hole"));
	addComponent!TypeVariable(f.mod, e);

	assert(!typeCheck(f.mod, e));
	assert(diagnostics().hasErrors());
	diagnostics().clear();
}

unittest {
	// The builtin `_` placeholder carries the tag as a marker rather than as a
	// hole somebody wrote, so it must not report against itself.
	import doir.pipeline.sema.type_variables : inferencePlaceholder, introduceTypeVariables;

	auto f = makeModuleWithBuiltins();
	scope(exit) freeModule(f.mod);
	diagnostics().clear();

	immutable placeholder = inferencePlaceholder(f.mod, f.root);
	assert(introduceTypeVariables(f.mod, placeholder));
	assert(typeCheck(f.mod, placeholder));
	assert(!diagnostics().hasErrors());
}
