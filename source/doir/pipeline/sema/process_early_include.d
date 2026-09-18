/// `canonicalize.processEarlyInclude`: parses an `early_include("...")`'s file
/// straight into the surrounding block and replaces the call with the file's
/// byte count. Ported from sema/canonicalize/process_early_include.hpp.
module doir.pipeline.sema.process_early_include;

import ecrs.storage : EntityId, invalidEntity;

static import fp.dynarray;
import fp.dynarray : daBack = back, daLength = length;
import fp.string : strFree = free, strSlice = slice;

import doir.diagnostics;
import doir.file_manager : canonicalPath, getFileString;
import doir.interface_;
import doir.module_;
import doir.parser : parseFile;

@nogc nothrow:


/// What the pass needs beyond the entity: the builder stack the parser pushes
/// onto. The C++ bound `parser` and `builders` into the system with
/// `std::bind`.
struct EarlyIncludeContext {
	/// The parser's stack of open blocks, as a libfp dynarray. The parser
	/// threads its stack through as a `ref` parameter; this is the one place
	/// that cannot, because the walkers fix the visitor signature and this
	/// context is filled in ahead of the walk - so it holds a pointer to the
	/// caller's array, which pushing onto it may reallocate.
	BlockBuilder** builders;
	bool guaranteeSourceLocation = true;
}

/// What `processEarlyIncludeVisitor` runs against. `doir.systems`' walkers take
/// their visitor as a compile-time alias (as `ecrs.system`'s own combinators
/// do), so a pass whose extra state is only known at runtime parks it here
/// instead of threading an untyped `ctx` through every walk. Thread-local,
/// like `doir.pipeline.sema.sort.newRoot`; a schedule fills it in right before the
/// `sorted!processEarlyIncludeVisitor` pass that reads it.
EarlyIncludeContext earlyIncludeContext;

bool processEarlyInclude(ref Module mod, EntityId subtree, ref EarlyIncludeContext context) @trusted {
	if (!(hasComponent!Call(mod, subtree) || hasComponent!LookupCall(mod, subtree))) return true;

	// NOTE: the C++ caches these two in function-local statics, which keys
	// them to whichever module ran the pass first. `resolveCached` is
	// per-module and cleared by canonicalize.sort, so it is used instead.
	immutable include = resolveCached(mod, "early_include", 1);
	immutable pointerSized = resolveCached(mod, "compiler.pointer_sized", 1);

	bool isInclude = false;
	if (hasComponent!Call(mod, subtree))
		isInclude = getComponent!Call(mod, subtree).related[0] == include;
	else if (hasComponent!LookupCall(mod, subtree)) {
		auto lookup = getComponent!LookupCall(mod, subtree).lookup;
		// NOTE: the C++ compares `lookup.resolved() == include`, i.e. a bool
		// against an entity id. Comparing the resolved *entity* is what that
		// line reaches for, and is what the unresolved branch below already does.
		if (lookup.resolved()) isInclude = lookup.entity() == include;
		else isInclude = lookup.name().view == "early_include";
	}
	if (!isInclude) return true;

	immutable blockEntity = findParent(mod, subtree);
	if (blockEntity == invalidEntity) return true; // TODO: Should this be an error?
	if (!hasComponent!Block(mod, blockEntity)) return true; // TODO: Should this be an error?

	if (!hasAnyInputs(mod, subtree)) {
		expectsXInputs(mod, subtree, "early_include", "one");
		return false;
	}
	auto inputs = inputsOf(mod, subtree);
	scope(exit) inputs.free();
	if (inputs.length != 1) {
		expectsXInputs(mod, subtree, "early_include", "one");
		return false;
	}

	EntityId input;
	if (inputs[0].resolved()) input = inputs[0].entity();
	else input = resolveLookupName(mod, inputs[0].name(), subtree);
	input = resolveAlias(mod, input);
	if (input == invalidEntity) {
		expectsXInputs(mod, subtree, "early_include", "one");
		return false;
	}
	if (!hasComponent!DString(mod, input)) {
		// TODO: It would probably be good to relax this constraint in the future
		parameterError(mod, subtree, "early_include", 0, " must evaluate to a string constant");
		return false;
	}

	char* path = canonicalPath(getComponent!DString(mod, input).value.view);
	if (path is null) {
		parameterError(mod, subtree, "early_include", 0, " must evaluate to a string constant");
		return false;
	}
	scope(exit) strFree(path);
	auto internedPath = internIn(mod, strSlice(path));

	fp.dynarray.pushBack(*context.builders, createBlockBuilder(mod));
	parseFile(mod, *context.builders, internedPath.view, context.guaranteeSourceLocation);
	immutable blockE = daBack(*context.builders).block;
	fp.dynarray.popBack(*context.builders);
	if (diagnostics().hasErrors()) return false;

	immutable offset = blockOffsetOf(mod, blockEntity, subtree);
	inlineInto(mod, blockE, blockEntity, offset + 1);

	// Replace the call with number of bytes in the file
	if (hasComponent!Call(mod, subtree)) {
		removeComponent!Call(mod, subtree);
		removeComponent!FunctionInputs(mod, subtree);
		removeComponent!TypeOf(mod, subtree);
	} else {
		removeComponent!LookupCall(mod, subtree);
		removeComponent!LookupFunctionInputs(mod, subtree);
		removeComponent!LookupTypeOf(mod, subtree);
	}

	bool ok;
	auto contents = getFileString(internedPath.view, ok);
	attachNumber(mod, subtree, pointerSized, ok ? contents.length : 0);
	return true;
}

/// Visitor adaptor for `doir.systems`, bound to `earlyIncludeContext`.
bool processEarlyIncludeVisitor(ref Module mod, EntityId subtree) {
	return processEarlyInclude(mod, subtree, earlyIncludeContext);
}
