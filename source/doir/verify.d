/// Structural validation of the IR. Ported from interface.verify.cpp.
///
/// Every `throw std::runtime_error("TODO: ...")` in the original becomes a
/// `panic` here: those throws were never caught anywhere in the C++ program
/// either, so reaching one has always terminated the compiler.
module doir.verify;

import core.stdc.stdio : printf;

import diagnose.diagnostics : Ansi, Diagnostic, Manager, pushAnnotation;
import diagnose.source_location : Pair;
import ecrs.storage : EntityId, invalidEntity;

static import fp.dynarray;
import fp.dynarray : daLength = length;

import doir.diagnostics;
import doir.interface_;
import doir.module_;
import doir.string_helpers : InternedString, text;

@nogc nothrow:


/// Checks that `subtree` names a live entity slot. Named so it does not hide
/// `doir.module_.entityExists`, the predicate it reports on - a local free
/// function hides every imported one that shares its name.
bool entityStructure(ref Manager diags, ref Module mod, EntityId subtree) @trusted {
	if (!entityExists(mod, subtree))
		panic(entityIsFree(mod, subtree)
			? "TODO: entity removed error" : "TODO: invalid entity error");
	return true;
}

/// Checks that `ident` is a well-formed identifier, and (unless
/// `allowBuiltins`) that it isn't one of the reserved builtin names.
bool identifierStructure(ref Manager diags, ref Module mod, InternedString ident, bool allowBuiltins = true) @trusted {
	char* invalidMessage = null;
	scope(exit) { import fp.string : strFree = free; strFree(invalidMessage); }
	size_t invalidOffset = 0;

	if (ident.view.length > 0 && ident[0] == '%') {
		if (ident.view.length == 1) {
			invalidMessage = text("A ", DoirAnsi.info, "%", Ansi.reset,
				" in an identifier must by followed by a number");
			invalidOffset = 0;
		}
		foreach (i; 1 .. ident.view.length)
			if (!(ident[i] >= '0' && ident[i] <= '9')) {
				if (invalidMessage !is null) { import fp.string : strFree = free; strFree(invalidMessage); }
				invalidMessage = text("Only numbers can follow a ", DoirAnsi.info, "%",
					Ansi.reset);
				invalidOffset = i;
				break;
			}
	}

	if (!allowBuiltins) {
		foreach (builtin; builtinNames)
			if (ident.view == builtin) {
				if (invalidMessage !is null) { import fp.string : strFree = free; strFree(invalidMessage); }
				invalidMessage = text("Reserved identifier ", DoirAnsi.type, ident.view,
					Ansi.reset, " not allowed here");
				invalidOffset = 0;
				break;
			}
	}

	if (invalidMessage !is null) {
		auto diag = &diags.push(generateDiagnostic(DiagnosticType.InvalidIdentifier,
			findTextLocation(mod, ident.view), workingSource(mod),
			workingFileOr(mod, invalidFileName)));
		Diagnostic.Annotation annotation;
		annotation.position = Pair(
			diag.location.start.line, diag.location.start.column + invalidOffset);
		annotation.message = text(invalidMessage);
		annotation.color = DoirAnsi.info;
		pushAnnotation(*diag, annotation);
		return false;
	}

	return true;
}

private bool verifyLookupStructure(ref Manager diags, ref Module mod, ref const Lookup l) {
	if (l.resolved()) {
		if (!entityStructure(diags, mod, l.entity())) return false;
	} else if (!identifierStructure(diags, mod, l.name())) return false;
	return true;
}

private EntityId maxOfRelated(ref Module mod, EntityId blockEntity) @trusted {
	auto block = &getComponent!Block(mod, blockEntity);
	EntityId best = 0;
	foreach (i; 0 .. daLength(block.related))
		if (block.related[i] > best) best = block.related[i];
	return best;
}

/// Walks `subtree` checking that each entity carries a coherent set of
/// components for whatever kind of declaration it is.
bool structure(ref Manager diags, ref Module mod, EntityId subtree, bool topLevel = true, EntityId builtinEnd = invalidEntity) @trusted {
	bool valid = false;

	if (builtinEnd == invalidEntity) {
		immutable compiler = resolveLookupName(mod, internIn(mod, "compiler"), 1);
		if (compiler == invalidEntity) builtinEnd = 1;
		else {
			auto b = &getComponent!Block(mod, compiler);
			immutable maxRelated = maxOfRelated(mod, compiler);
			immutable lastChild = b.related[daLength(b.related) - 1];
			immutable lastMax = maxOfRelated(mod, lastChild);
			builtinEnd = compiler;
			if (maxRelated > builtinEnd) builtinEnd = maxRelated;
			if (lastMax > builtinEnd) builtinEnd = lastMax;
		}
	}

	// It momentarily seemed like a good idea to require everything to have a
	// source location... (see the commented-out check in the original).

	if (hasComponent!TypeOf(mod, subtree) || hasComponent!LookupTypeOf(mod, subtree)) {
		valid = true;

		auto t = typeOfLookup(mod, subtree);
		if (!verifyLookupStructure(diags, mod, t)) valid = false;

		if (hasComponent!Pointer(mod, subtree)
			|| hasComponent!TypeDefinition(mod, subtree)
			|| hasComponent!Alias(mod, subtree)
			|| hasComponent!LookupLookup(mod, subtree)
			|| hasComponent!LookupAlias(mod, subtree))
		{
			panic("TODO: Invalid component");
		}

		immutable valueless = flagsSet(mod, subtree, Flags.Valueless);
		immutable number = hasComponent!Number(mod, subtree);
		immutable string_ = hasComponent!DString(mod, subtree);
		immutable call = hasComponent!Call(mod, subtree);
		immutable callLookup = hasComponent!LookupCall(mod, subtree);
		immutable functionDef = hasComponent!FunctionReturnType(mod, subtree);
		immutable functionDefLookup = hasComponent!LookupFunctionReturnType(mod, subtree);
		immutable block = hasComponent!Block(mod, subtree);

		immutable count = cast(size_t) valueless + number + string_ + call + callLookup
			+ functionDef + functionDefLookup + block;
		switch (count) {
			case 0:
				panic("TODO: Value required error");
			case 1:
				// Do Nothing we are good :)
				break;
			case 2:
				// A function with a body carries both its return type and that
				// body. A function *declared* but not defined - `f : some_t`
				// where `some_t` is a function type - carries the return type
				// `sema.materializeFunctionTypesAndParameters` copied off its
				// type, plus the `Valueless` the parser set for the missing
				// `=`. Both facts are true of it, and every declaration in
				// `standard.doir` has that shape, so it is not an error. (The
				// builtin block reaches the same state without the flag, via
				// `attachValuelessFunction`, which is why this went unnoticed.)
				if (!((functionDef && block) || (functionDefLookup && block)
					|| ((functionDef || functionDefLookup) && valueless)))
					panic("TODO: Only one value is allowed error");
				break;
			default:
				panic("TODO: Only one value is allowed error");
		}

		if (!(call || callLookup || functionDef || functionDefLookup) && hasComponent!Flags(mod, subtree)) {
			if ((!block && flagsSet(mod, subtree, Flags.Flatten))
				|| flagsSet(mod, subtree, Flags.Inline)
				|| flagsSet(mod, subtree, Flags.Pure)
				|| flagsSet(mod, subtree, Flags.Tail))
			{
				panic("TODO: Invalid flags");
			}
		}
		if (flagsSet(mod, subtree, Flags.Constant))
			panic("TODO: Only pointer types can be marked constant");

		if (call || callLookup) {
			// The original resolves the callee and inputs here purely to keep
			// the (commented-out) recursive checks compiling; nothing is
			// validated, so nothing is done.
		} else if (functionDef || functionDefLookup) {
			if (!t.resolved())
				panic("TODO: function types can't be looked up");

			immutable ft = resolveTypeModifications(mod, t.entity());
			auto inputs = inputsOf(mod, ft);
			scope(exit) fp.dynarray.free(inputs);

			if (hasComponent!FunctionParameterNames(mod, subtree)) {
				immutable nameCount = getComponent!FunctionParameterNames(mod, subtree).length;
				if (nameCount != daLength(inputs))
					panic("TODO: The number of parameter names must match the number of parameters");
			}

			if (hasComponent!Block(mod, subtree)) {
				auto parameters = associatedParameters(mod, daLength(inputs), subtree);
				scope(exit) fp.dynarray.free(parameters);

				if (daLength(parameters) != daLength(inputs))
					panic("TODO: A different number of parameters are defined than declared.");

				if (hasComponent!FunctionParameterNames(mod, subtree)) {
					auto names = getComponent!FunctionParameterNames(mod, subtree).slice;
					foreach (i; 0 .. daLength(parameters))
						if (hasComponent!Name(mod, parameters[i])
							&& names[i] != getComponent!Name(mod, parameters[i]).value)
							panic("TODO: Parameter names differ");
				}
			}
		}

	} else if (hasComponent!TypeDefinition(mod, subtree)) {
		valid = true;

		if (!(hasComponent!Block(mod, subtree)
			|| hasComponent!FunctionReturnType(mod, subtree)
			|| hasComponent!LookupFunctionReturnType(mod, subtree)
			|| hasComponent!Pointer(mod, subtree)))
		{
			printf("%u\n", subtree);
			panic("Types are required to have a `block`, function types are required to have a `function_inputs`, and pointers/arrays must have `pointer`");
		}

		if (hasComponent!FunctionParameter(mod, subtree)
			|| hasComponent!Alias(mod, subtree)
			|| hasComponent!TypeOf(mod, subtree)
			|| hasComponent!Number(mod, subtree)
			|| hasComponent!DString(mod, subtree)
			|| hasComponent!Call(mod, subtree)
			|| hasComponent!LookupLookup(mod, subtree)
			|| hasComponent!LookupAlias(mod, subtree)
			|| hasComponent!LookupTypeOf(mod, subtree)
			|| hasComponent!LookupCall(mod, subtree))
		{
			panic("TODO: Invalid component attached");
		}

		if (hasComponent!FunctionInputs(mod, subtree)) {
			auto inputs = inputsOf(mod, subtree);
			scope(exit) fp.dynarray.free(inputs);

			if (hasComponent!FunctionParameterNames(mod, subtree)) {
				immutable nameCount = getComponent!FunctionParameterNames(mod, subtree).length;
				if (nameCount != daLength(inputs))
					panic("TODO: The number of parameter names must match the number of parameters");
			}
		}

		if (hasComponent!Pointer(mod, subtree)) {
			immutable type = resolveCached(mod, "type", 1);
			immutable base = getComponent!Pointer(mod, subtree).related[0];
			if (!(hasComponent!TypeDefinition(mod, base)
				|| (hasComponent!TypeOf(mod, base) && getComponent!TypeOf(mod, base).related[0] == type)))
			{
				panic("TODO: Pointers must have a type as their base");
			}
		}

		if (flagsSet(mod, subtree, Flags.Valueless) || flagsSet(mod, subtree, Flags.Namespace))
			panic("TODO: Invalid flags");

	} else if (flagsSet(mod, subtree, Flags.Namespace)) {
		valid = true;

		if (!hasComponent!Block(mod, subtree))
			panic("Namespaces are required to have a block");

		if (hasComponent!Flags(mod, subtree)) {
			auto flags = getComponent!Flags(mod, subtree);
			flags.flags &= ~cast(ushort) Flags.Namespace;
			if (!(flags.flags == Flags.None || flags.flags == Flags.Export))
				panic("Invalid flags");
		}

		if (hasComponent!Pointer(mod, subtree)
			|| hasComponent!FunctionReturnType(mod, subtree)
			|| hasComponent!FunctionInputs(mod, subtree)
			|| hasComponent!FunctionParameter(mod, subtree)
			|| hasComponent!TypeDefinition(mod, subtree)
			|| hasComponent!Alias(mod, subtree)
			|| hasComponent!TypeOf(mod, subtree)
			|| hasComponent!Number(mod, subtree)
			|| hasComponent!DString(mod, subtree)
			|| hasComponent!Call(mod, subtree)
			|| hasComponent!LookupLookup(mod, subtree)
			|| hasComponent!LookupFunctionReturnType(mod, subtree)
			|| hasComponent!LookupFunctionInputs(mod, subtree)
			|| hasComponent!LookupAlias(mod, subtree)
			|| hasComponent!LookupTypeOf(mod, subtree)
			|| hasComponent!LookupCall(mod, subtree))
		{
			panic("TODO: Invalid component attached");
		}

		if (flagsSet(mod, subtree, Flags.Valueless))
			panic("TODO: Invalid flags");

	} else if (hasComponent!Alias(mod, subtree) || hasComponent!LookupAlias(mod, subtree)) {
		if (hasComponent!Pointer(mod, subtree)
			|| hasComponent!FunctionReturnType(mod, subtree)
			|| hasComponent!FunctionInputs(mod, subtree)
			|| hasComponent!FunctionParameter(mod, subtree)
			|| hasComponent!Block(mod, subtree)
			|| hasComponent!TypeDefinition(mod, subtree)
			|| hasComponent!TypeOf(mod, subtree)
			|| hasComponent!Number(mod, subtree)
			|| hasComponent!DString(mod, subtree)
			|| hasComponent!Call(mod, subtree)
			|| hasComponent!LookupLookup(mod, subtree)
			|| hasComponent!LookupFunctionReturnType(mod, subtree)
			|| hasComponent!LookupFunctionInputs(mod, subtree)
			|| hasComponent!LookupTypeOf(mod, subtree)
			|| hasComponent!LookupCall(mod, subtree))
		{
			panic("TODO: Invalid component attached");
		}

		if (hasComponent!Flags(mod, subtree)) {
			immutable flags = getComponent!Flags(mod, subtree).flags;
			if (!(flags == Flags.None || flags == Flags.Export || flags == Flags.Comptime))
				panic("Invalid flags");
		}

	} else if (hasComponent!Block(mod, subtree)) {
		if (hasComponent!Flags(mod, subtree)) {
			immutable flags = getComponent!Flags(mod, subtree).flags;
			if (!(flags == Flags.None || flags == Flags.Flatten))
				panic("Invalid flags");
		}

		if (topLevel) valid = true;
		else panic("TODO: A standalone block not as part of an assignment is only allowed at the top level!");
	}

	if (entityIsFree(mod, subtree))
		panic("TODO: Referenced deleted entity");

	if (hasComponent!Name(mod, subtree))
		if (!identifierStructure(diags, mod, getComponent!Name(mod, subtree).value, subtree <= builtinEnd))
			valid = false;

	if (hasComponent!Parent(mod, subtree)) {
		immutable parent = getComponent!Parent(mod, subtree).related[0];
		if (!hasComponent!Block(mod, parent))
			panic("TODO: Parents must point to a valid block");
		auto block = &getComponent!Block(mod, parent);
		bool listed = false;
		foreach (i; 0 .. daLength(block.related))
			if (block.related[i] == subtree) { listed = true; break; }
		if (!listed)
			panic("TODO: The parent of an entity must also list that entity in its block");
	}

	if (hasComponent!Block(mod, subtree)) {
		{
			EntityMap seen; // used as a set: each entity maps to itself
			scope(exit) seen.free();
			auto related = &getComponent!Block(mod, subtree).related;
			foreach (i; 0 .. daLength(*related)) {
				if (seen.contains((*related)[i]))
					panic("TODO: Duplicate elements in block");
				seen.set((*related)[i], (*related)[i]);
			}
		}

		for (size_t i = 0; i < daLength(getComponent!Block(mod, subtree).related); ++i) {
			immutable e = getComponent!Block(mod, subtree).related[i];
			if (hasComponent!Parent(mod, e)) {
				immutable parent = getComponent!Parent(mod, e).related[0];
				if (parent != subtree)
					panic("TODO: Children of a block must list that block as their parent");
			}
			if (!structure(diags, mod, e, false, builtinEnd))
				valid = false;
		}
	}

	return valid;
}


// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
// Ported from tests/verify.test.cpp.
//
// The C++ suite's three `CHECK_THROWS_AS(..., std::runtime_error)` cases for
// `entity_exists` have no analogue: those throws became `panic` (abort) in
// this port, because `-betterC` has no exceptions and nothing ever caught them
// in the C++ either. The positive case below still covers the bounds check
// that regression was about.

version (unittest) {
	import diagnose.diagnostics : freeManager = free;
	import tests.pipeline_helper;
}

unittest {
	// `entityStructure` accepts a live entity allocated after other entities were
	// removed. (The C++ version bounds checked against `entity_count()`, which
	// shrinks for every removed entity, instead of the allocated id range, so a
	// still-live high-numbered entity would wrongly fail the check.)
	auto mod = createModule();
	scope(exit) freeModule(mod);

	EntityId[6] ids;
	foreach (i; 0 .. 6) ids[i] = addEntity(mod);

	removeEntity(mod, ids[1]);
	removeEntity(mod, ids[3]);

	Manager diags;
	scope(exit) freeManager(diags);
	assert(entityStructure(diags, mod, ids[5]));
}

unittest { // identifierStructure accepts a well formed %N ssa identifier
	auto f = makeModuleWithBuiltins();
	scope(exit) freeModule(f.mod);
	Manager diags;
	scope(exit) freeManager(diags);
	assert(identifierStructure(diags, f.mod, internIn(f.mod, "%0")));
	assert(diags.count() == 0);
}

unittest { // identifierStructure rejects a %-identifier with non-digit characters
	auto f = makeModuleWithBuiltins();
	scope(exit) freeModule(f.mod);
	Manager diags;
	scope(exit) freeManager(diags);
	assert(!identifierStructure(diags, f.mod, internIn(f.mod, "%abc")));
	assert(diags.count() == 1);
	assert(diags.hasErrors());
}

unittest { // identifierStructure rejects a lone %
	auto f = makeModuleWithBuiltins();
	scope(exit) freeModule(f.mod);
	Manager diags;
	scope(exit) freeManager(diags);
	assert(!identifierStructure(diags, f.mod, internIn(f.mod, "%")));
}

unittest { // identifierStructure rejects builtin names only when allowBuiltins is false
	auto f = makeModuleWithBuiltins();
	scope(exit) freeModule(f.mod);
	Manager diags;
	scope(exit) freeManager(diags);
	assert(identifierStructure(diags, f.mod, internIn(f.mod, "type"), true));
	assert(!identifierStructure(diags, f.mod, internIn(f.mod, "type"), false));
}

unittest { // identifierStructure does not crash on an empty identifier
	auto f = makeModuleWithBuiltins();
	scope(exit) freeModule(f.mod);
	Manager diags;
	scope(exit) freeManager(diags);
	assert(identifierStructure(diags, f.mod, InternedString.init));
}

unittest { // a freshly built builtin block passes verify.structure
	auto f = makeModuleWithBuiltins();
	scope(exit) freeModule(f.mod);
	Manager diags;
	scope(exit) freeManager(diags);
	assert(structure(diags, f.mod, f.root));
	assert(!diags.hasErrors());
}

unittest {
	// A malformed name makes `structure` report the entity invalid rather than
	// panicking: it is a diagnostic about the program, not about the IR.
	auto f = makeModuleWithBuiltins();
	scope(exit) freeModule(f.mod);
	Manager diags;
	scope(exit) freeManager(diags);

	auto block = BlockBuilder(f.root, &f.mod);
	immutable byte_ = resolveLookupName(f.mod, internIn(f.mod, "compiler.byte"), f.root);
	pushNumber(block, internIn(f.mod, "%nope"), byte_, 1);

	assert(!structure(diags, f.mod, f.root));
	assert(diags.hasErrors());
}

unittest {
	// A function definition may carry its own parameter names, which have to
	// agree in number - and in spelling - with the ones its parameters were
	// declared under.
	auto f = makeModuleWithBuiltins();
	scope(exit) freeModule(f.mod);
	Manager diags;
	scope(exit) freeManager(diags);

	auto block = BlockBuilder(f.root, &f.mod);
	immutable byte_ = resolveLookupName(f.mod, internIn(f.mod, "compiler.byte"), f.root);
	Lookup[1] inputs = [Lookup(byte_)];
	InternedString[1] names = [internIn(f.mod, "p")];
	immutable ft = pushFunctionType(block, internIn(f.mod, "ft"), inputs[], Lookup(byte_), true, names[]);

	auto fb = pushFunction(block, internIn(f.mod, "fn"), ft, true);
	// The names the *definition* carries, over and above the type's.
	addComponent!FunctionParameterNames(f.mod, fb.builder.block).assign(names[]);

	assert(structure(diags, f.mod, f.root));
	assert(!diags.hasErrors());
}

unittest {
	// A top-level block is allowed to carry flags, as long as they are only
	// the ones a block can have.
	auto f = makeModuleWithBuiltins();
	scope(exit) freeModule(f.mod);
	Manager diags;
	scope(exit) freeManager(diags);

	getOrAddComponent!Flags(f.mod, f.root).flags = Flags.None;
	assert(structure(diags, f.mod, f.root));

	getComponent!Flags(f.mod, f.root).flags = Flags.Flatten;
	assert(structure(diags, f.mod, f.root));
	assert(!diags.hasErrors());
}
