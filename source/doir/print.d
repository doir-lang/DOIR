/// Rendering the IR back out as DOIR source. Ported from print.cpp.
///
/// The C++ streamed into a `std::ostream`; here everything accumulates into a
/// libfp string, which `printModule` then writes to a `FILE*`. Same output,
/// no iostreams.
module doir.print;

import core.stdc.stdio : FILE, fwrite, stdout;

import diagnose.source_location : Detailed, SourceLocation;
import ecrs.storage : EntityId, invalidEntity;

import fp.dynarray : daLength = length;
import fp.string : concatenateSlice, strFree = free, strLength = length, strSlice = slice;

import doir.diagnostics : appendText, text;
import doir.interface_;
import doir.module_;
import doir.string_helpers : escapePythonString;

@nogc nothrow:



private void appendIndent(ref char* out_, bool pretty, size_t indent) {
	if (!pretty) return;
	foreach (_; 0 .. indent) concatenateSlice(out_, "\t");
}

private void appendEntity(ref char* out_, EntityId e) {
	appendText(out_, cast(size_t) e);
}

private void appendLocation(ref char* out_, ref const Detailed location) @trusted {
	char* rendered = (cast(Detailed) location).toDisplayString();
	scope(exit) strFree(rendered);
	concatenateSlice(out_, strSlice(rendered));
}

/// Renders a function type as `(a:T,b:U)->V`. Returns a libfp string.
char* printFunctionType(ref Module mod, EntityId type, bool debug_) @trusted {
	import core.stdc.stdio : snprintf;

	auto inputs = inputsOf(mod, type);
	scope(exit) doir.interface_.free(inputs);

	auto returnType = returnTypeOf(mod, type);

	char* out_ = null;
	concatenateSlice(out_, "(");
	foreach (i; 0 .. inputs.length) {
		if (i > 0) concatenateSlice(out_, ",");

		if (hasComponent!FunctionParameterNames(mod, type))
			concatenateSlice(out_, getComponent!FunctionParameterNames(mod, type).slice[i].view);
		else {
			char[24] buffer;
			immutable n = snprintf(buffer.ptr, buffer.length, "a%zu", i);
			concatenateSlice(out_, buffer[0 .. n]);
		}

		concatenateSlice(out_, ":");
		char* name = printLookupName(mod, inputs[i], debug_);
		concatenateSlice(out_, strSlice(name));
		strFree(name);
	}
	concatenateSlice(out_, ")");

	if (!returnType.isNull) {
		concatenateSlice(out_, "->");
		char* name = printLookupName(mod, returnType.get, debug_);
		concatenateSlice(out_, strSlice(name));
		strFree(name);
	}
	if (debug_) {
		concatenateSlice(out_, "[");
		appendEntity(out_, type);
		concatenateSlice(out_, "]");
	}
	return out_;
}

/// Renders whatever `lookup` names: a dotted path for a named entity, the
/// function type for an anonymous function type, or `%id` otherwise.
char* printLookupName(ref Module mod, Lookup lookup, bool debug_) @trusted {
	char* out_ = null;

	if (!lookup.resolved()) {
		if (debug_) {
			concatenateSlice(out_, "lookup(");
			concatenateSlice(out_, lookup.name().view);
			concatenateSlice(out_, ")");
		} else concatenateSlice(out_, lookup.name().view);
		return out_;
	}

	if (hasComponent!Name(mod, lookup.entity())) {
		concatenateSlice(out_, getComponent!Name(mod, lookup.entity()).value.view);

		// Namespace-qualify by walking up the parent chain, prefixing as we go.
		auto parent = findParent(mod, lookup.entity());
		while (flagsSet(mod, parent, Flags.Namespace) && hasComponent!Name(mod, parent)) {
			char* prefixed = null;
			concatenateSlice(prefixed, getComponent!Name(mod, parent).value.view);
			concatenateSlice(prefixed, ".");
			concatenateSlice(prefixed, strSlice(out_));
			strFree(out_);
			out_ = prefixed;
			parent = findParent(mod, parent);
		}

		if (debug_) {
			concatenateSlice(out_, "[");
			appendEntity(out_, lookup.entity());
			concatenateSlice(out_, "]");
		}
		return out_;
	}

	if (hasComponent!TypeDefinition(mod, lookup.entity()) && hasAnyInputs(mod, lookup.entity())) {
		strFree(out_);
		return printFunctionType(mod, lookup.entity(), debug_);
	}

	concatenateSlice(out_, "%");
	appendEntity(out_, lookup.entity());
	return out_;
}

private struct CommonElements {
	char* ident;
	char* type;
	Detailed location;
	bool hasLocation;
	const(char)[] export_;
}

private void free(ref CommonElements c) { strFree(c.ident); strFree(c.type); }

private CommonElements commonAssignmentElements(ref Module mod, EntityId subtree, bool debug_) @trusted {
	CommonElements out_;

	if (hasComponent!Name(mod, subtree)) {
		out_.ident = text(getComponent!Name(mod, subtree).value.view);
		if (debug_) {
			concatenateSlice(out_.ident, "[");
			appendEntity(out_.ident, subtree);
			concatenateSlice(out_.ident, "]");
		}
	} else {
		out_.ident = text("%");
		appendEntity(out_.ident, subtree);
	}

	if (hasComponent!TypeOf(mod, subtree))
		out_.type = printLookupName(mod, Lookup(getComponent!TypeOf(mod, subtree).related[0]), debug_);
	else if (hasComponent!LookupTypeOf(mod, subtree))
		out_.type = printLookupName(mod, getComponent!LookupTypeOf(mod, subtree).lookup, debug_);
	else if (hasComponent!TypeDefinition(mod, subtree))
		out_.type = text("type");
	else if (flagsSet(mod, subtree, Flags.Namespace))
		out_.type = text("namespace");
	else
		out_.type = text("<error>");

	if (hasComponent!Detailed(mod, subtree)) {
		out_.location = getComponent!Detailed(mod, subtree);
		out_.hasLocation = true;
	} else if (hasComponent!SourceLocation(mod, subtree)) {
		auto location = getComponent!SourceLocation(mod, subtree);
		out_.location = location.toDetailed(sourceOf(mod, location));
		out_.hasLocation = true;
	}

	out_.export_ = flagsSet(mod, subtree, Flags.Export) ? "export " : "";
	return out_;
}

private void printDebugExtras(ref char* out_, ref Module mod, EntityId subtree, bool debug_) @trusted {
	if (!debug_) return;

	if (hasComponent!ComptimeNumber(mod, subtree)) {
		concatenateSlice(out_, " [comp: ");
		appendText(out_, getComponent!ComptimeNumber(mod, subtree).value);
		concatenateSlice(out_, "]");
	} else if (hasComponent!ComptimeString(mod, subtree)) {
		concatenateSlice(out_, " [comp: \"");
		concatenateSlice(out_, getComponent!ComptimeString(mod, subtree).value.view);
		concatenateSlice(out_, "\"]");
	} else if (flagsSet(mod, subtree, Flags.Comptime)) {
		concatenateSlice(out_, " [comp]");
	}

	if (hasComponent!AssignedRegister(mod, subtree)) {
		concatenateSlice(out_, " [reg: ");
		appendText(out_, getComponent!AssignedRegister(mod, subtree).reg);
		concatenateSlice(out_, "]");
	}
}

private void printBlock(ref char* out_, ref Module mod, EntityId blockEntity, bool pretty, bool debug_, bool skipParameters, size_t indent) @trusted {
	concatenateSlice(out_, "{");
	if (pretty) concatenateSlice(out_, "\n");

	for (size_t i = 0; i < daLength(getComponent!Block(mod, blockEntity).related); ++i) {
		immutable elem = getComponent!Block(mod, blockEntity).related[i];
		if (skipParameters && hasComponent!FunctionParameter(mod, elem)) continue;
		printImpl(out_, mod, elem, pretty, debug_, indent + 1);
		printDebugExtras(out_, mod, elem, debug_);
		concatenateSlice(out_, pretty ? "\n" : ";");
	}

	appendIndent(out_, pretty, indent);
	concatenateSlice(out_, "}");
}

private void printTypeOf(ref char* out_, ref Module mod, EntityId subtree, bool pretty, bool debug_, size_t indent) @trusted {
	if (flagsSet(mod, subtree, Flags.Valueless)) {
		auto c = commonAssignmentElements(mod, subtree, debug_);
		scope(exit) c.free();
		appendIndent(out_, pretty, indent);
		appendText(out_, c.export_, strSlice(c.ident), pretty ? ": " : ":", strSlice(c.type));
		if (c.hasLocation) appendLocation(out_, c.location);

	} else if (hasComponent!Call(mod, subtree) || hasComponent!LookupCall(mod, subtree)
		|| (hasComponent!PrintAsCall(mod, subtree) && !debug_))
	{
		auto c = commonAssignmentElements(mod, subtree, debug_);
		scope(exit) c.free();

		Lookup call = hasComponent!Call(mod, subtree)
			? Lookup(getComponent!Call(mod, subtree).related[0])
			: hasComponent!PrintAsCall(mod, subtree)
				? Lookup(getComponent!PrintAsCall(mod, subtree).related[0])
				: getComponent!LookupCall(mod, subtree).lookup;

		auto inputs = inputsOf(mod, subtree);
		scope(exit) doir.interface_.free(inputs);

		char* flags = null;
		scope(exit) strFree(flags);
		if (hasComponent!Flags(mod, subtree)) {
			if (flagsSet(mod, subtree, Flags.Inline)) concatenateSlice(flags, "inline ");
			if (flagsSet(mod, subtree, Flags.Flatten)) concatenateSlice(flags, "flatten ");
			if (flagsSet(mod, subtree, Flags.Tail)) concatenateSlice(flags, "tail ");
			if (debug_ && flagsSet(mod, subtree, Flags.Comptime)) concatenateSlice(flags, "comptime ");
		}

		appendIndent(out_, pretty, indent);
		appendText(out_, c.export_, strSlice(c.ident), pretty ? ": " : ":", strSlice(c.type),
			pretty ? " = " : "=", flags is null ? "" : strSlice(flags));
		{
			char* name = printLookupName(mod, call, debug_);
			scope(exit) strFree(name);
			concatenateSlice(out_, strSlice(name));
		}
		concatenateSlice(out_, "(");
		foreach (i; 0 .. inputs.length) {
			if (i > 0) concatenateSlice(out_, pretty ? ", " : ",");
			char* name = printLookupName(mod, inputs[i], debug_);
			scope(exit) strFree(name);
			concatenateSlice(out_, strSlice(name));
		}
		concatenateSlice(out_, ")");

	} else if (hasComponent!Number(mod, subtree)) {
		auto c = commonAssignmentElements(mod, subtree, debug_);
		scope(exit) c.free();
		appendIndent(out_, pretty, indent);
		appendText(out_, c.export_, strSlice(c.ident), pretty ? ": " : ":", strSlice(c.type),
			pretty ? " = " : "=", getComponent!Number(mod, subtree).value);
		if (c.hasLocation) appendLocation(out_, c.location);

	} else if (hasComponent!DString(mod, subtree)) {
		auto c = commonAssignmentElements(mod, subtree, debug_);
		scope(exit) c.free();
		char* escaped = escapePythonString(getComponent!DString(mod, subtree).value.view);
		scope(exit) strFree(escaped);
		appendIndent(out_, pretty, indent);
		appendText(out_, c.export_, strSlice(c.ident), pretty ? ": " : ":", strSlice(c.type),
			pretty ? " = " : "=", "\"", escaped is null ? "" : strSlice(escaped), "\"");
		if (c.hasLocation) appendLocation(out_, c.location);

	} else if (hasComponent!FunctionReturnType(mod, subtree) || hasComponent!LookupFunctionReturnType(mod, subtree)) {
		auto c = commonAssignmentElements(mod, subtree, debug_);
		scope(exit) c.free();
		appendIndent(out_, pretty, indent);
		appendText(out_, c.export_, debug_ ? "f:" : "", strSlice(c.ident), pretty ? ": " : ":");

		auto lookup = typeOfLookup(mod, subtree);
		if (!lookup.resolved()) {
			appendText(out_, strSlice(c.type), pretty ? " = " : "=");
			printBlock(out_, mod, subtree, pretty, debug_, true, indent);
		} else {
			immutable ft = resolveAlias(mod, lookup.entity());
			immutable resolved = resolveTypeModifications(mod, ft);
			immutable ftIsModification = ft != resolved;

			if (hasComponent!Block(mod, subtree)) {
				auto inputs = inputsOf(mod, ft);
				scope(exit) doir.interface_.free(inputs);

				auto returnType = returnTypeOf(mod, ft);

				auto parameters = associatedParameters(mod, inputs.length, subtree);
				scope(exit) doir.interface_.free(parameters);

				if (ftIsModification)
					concatenateSlice(out_, strSlice(c.type));
				else {
					concatenateSlice(out_, "(");
					foreach (i; 0 .. parameters.length) {
						printImpl(out_, mod, parameters[i], pretty, debug_, 0);
						printDebugExtras(out_, mod, parameters[i], debug_);
						if (i < parameters.length - 1)
							concatenateSlice(out_, pretty ? ", " : ",");
					}
					concatenateSlice(out_, ")");

					if (!returnType.isNull) {
						concatenateSlice(out_, pretty ? " -> " : "->");
						char* name = printLookupName(mod, returnType.get, debug_);
						scope(exit) strFree(name);
						concatenateSlice(out_, strSlice(name));
					}
					if (debug_) {
						concatenateSlice(out_, "[");
						appendEntity(out_, ft);
						concatenateSlice(out_, "]");
					}
				}

				concatenateSlice(out_, pretty ? " = " : "=");
				printBlock(out_, mod, subtree, pretty, debug_, true, indent);
			} else { // Valueless function
				if (ftIsModification) concatenateSlice(out_, strSlice(c.type));
				else {
					char* ftText = printFunctionType(mod, ft, debug_);
					scope(exit) strFree(ftText);
					concatenateSlice(out_, strSlice(ftText));
				}
			}
		}

	} else if (hasComponent!Block(mod, subtree)) {
		auto c = commonAssignmentElements(mod, subtree, debug_);
		scope(exit) c.free();
		appendIndent(out_, pretty, indent);
		appendText(out_, c.export_, strSlice(c.ident), pretty ? ": " : ":", strSlice(c.type),
			pretty ? " = " : "=");
		printBlock(out_, mod, subtree, pretty, debug_, false, indent);

	} else concatenateSlice(out_, "<type_of error>");
}

private void printImpl(ref char* out_, ref Module mod, EntityId subtree, bool pretty, bool debug_, size_t indent = 0) @trusted {
	if (hasComponent!TypeOf(mod, subtree) || hasComponent!LookupTypeOf(mod, subtree)
		|| (hasComponent!PrintAsCall(mod, subtree) && !debug_))
	{
		printTypeOf(out_, mod, subtree, pretty, debug_, indent);

	} else if (hasComponent!TypeDefinition(mod, subtree)) {
		auto c = commonAssignmentElements(mod, subtree, debug_);
		scope(exit) c.free();
		appendIndent(out_, pretty, indent);
		appendText(out_, c.export_, strSlice(c.ident), pretty ? ": " : ":", strSlice(c.type),
			pretty ? " = " : "=");

		if (hasComponent!Block(mod, subtree))
			printBlock(out_, mod, subtree, pretty, debug_, false, indent);
		else if (hasComponent!Pointer(mod, subtree)) {
			auto p = &getComponent!Pointer(mod, subtree);
			char* base = printLookupName(mod, Lookup(p.related[0]), debug_);
			scope(exit) strFree(base);
			if (p.size == 0)
				appendText(out_, "type.pointer(", strSlice(base), ")");
			else
				appendText(out_, "type.array(", strSlice(base), ", ", p.size, ")");
		} else {
			char* ftText = printFunctionType(mod, subtree, debug_);
			scope(exit) strFree(ftText);
			concatenateSlice(out_, strSlice(ftText));
		}

	} else if (flagsSet(mod, subtree, Flags.Namespace)) {
		auto c = commonAssignmentElements(mod, subtree, debug_);
		scope(exit) c.free();
		appendIndent(out_, pretty, indent);
		appendText(out_, c.export_, strSlice(c.ident), pretty ? ": " : ":", strSlice(c.type),
			pretty ? " = " : "=");
		printBlock(out_, mod, subtree, pretty, debug_, false, indent);

	} else if (hasComponent!Alias(mod, subtree) || hasComponent!LookupAlias(mod, subtree)) {
		auto c = commonAssignmentElements(mod, subtree, debug_);
		scope(exit) c.free();

		Lookup aliasLookup;
		const(char)[] aliasFile;
		bool aliasHasFile;
		if (hasComponent!Alias(mod, subtree)) {
			auto a = &getComponent!Alias(mod, subtree);
			aliasLookup = Lookup(a.related[0]);
			aliasFile = a.file;
			aliasHasFile = a.hasFile;
		} else {
			auto a = &getComponent!LookupAlias(mod, subtree);
			aliasLookup = a.lookup;
			aliasFile = a.file;
			aliasHasFile = a.hasFile;
		}

		char* name = printLookupName(mod, aliasLookup, debug_);
		scope(exit) strFree(name);
		appendIndent(out_, pretty, indent);
		appendText(out_, c.export_, strSlice(c.ident), pretty ? ": " : ":", "alias",
			pretty ? " = " : "=", strSlice(name));
		if (debug_ && aliasHasFile)
			appendText(out_, "[", aliasFile, "]");

	} else concatenateSlice(out_, "<error>");
}

/// Renders `root` (or, when it is a block, its contents) as DOIR source.
/// Returns a libfp string the caller frees.
char* print(ref Module mod, EntityId root, bool pretty = true, bool debug_ = false) @trusted {
	char* out_ = null;

	if (hasComponent!Block(mod, root)) {
		for (size_t i = 0; i < daLength(getComponent!Block(mod, root).related); ++i) {
			immutable elem = getComponent!Block(mod, root).related[i];
			printImpl(out_, mod, elem, pretty, debug_, 0);
			printDebugExtras(out_, mod, elem, debug_);
			concatenateSlice(out_, pretty ? "\n" : ";");
		}
	} else {
		printImpl(out_, mod, root, pretty, debug_, 0);
		printDebugExtras(out_, mod, root, debug_);
	}

	return out_;
}

/// Renders `root` straight to `out`.
void printModule(FILE* out_, ref Module mod, EntityId root, bool pretty = true, bool debug_ = false) @trusted {
	char* rendered = print(mod, root, pretty, debug_);
	scope(exit) strFree(rendered);
	if (rendered !is null)
		fwrite(rendered, 1, strLength(rendered), out_);
}

/// `print` packaged as a system.
bool printSystem(ref Module mod, EntityId root = currentCanonicalizeRoot, bool pretty = true, bool debug_ = true) {
	import doir.pipeline.sema.sort : newRoot;
	printModule(stdout, mod, root == currentCanonicalizeRoot ? newRoot : root, pretty, debug_);
	return true;
}


// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
//
// `print` is the compiler's only way of showing its IR, and the driver calls
// it on whatever it happens to have built - including IR that is half-lowered,
// or malformed, or carries components no source text can produce. So rather
// than pin down an exact rendering (which would break on every change to the
// pipeline), these drive each shape the renderer knows how to draw and check
// the piece of output that shape is responsible for.

version (unittest) {
	import core.stdc.stdio : fclose, tmpfile;

	static import fp.dynarray;
	import fp.dynarray : daPushBack = pushBack;

	import doir.diagnostics : diagnostics;
	import doir.parser : parseSource;
	import doir.string_helpers : InternedString;
	import tests.pipeline_helper;

	/// True if `needle` occurs anywhere in `haystack`.
	private bool has(const(char)[] haystack, const(char)[] needle) {
		if (needle.length > haystack.length) return false;
		foreach (i; 0 .. haystack.length - needle.length + 1)
			if (haystack[i .. i + needle.length] == needle) return true;
		return false;
	}

	/// Renders `root` and hands the text to `check`, freeing it afterwards.
	private void rendered(ref Module mod, EntityId root, bool pretty, bool debug_,
		scope void delegate(const(char)[]) @nogc nothrow check)
	{
		char* out_ = print(mod, root, pretty, debug_);
		scope(exit) strFree(out_);
		check(out_ is null ? "" : strSlice(out_));
	}

	/// A module with its builtin block open, for hand-built IR.
	private struct PrintFixture {
		Module mod;
		BlockBuilder builder;
	}

	private PrintFixture makePrintFixture() {
		PrintFixture f;
		f.mod = createModule();
		f.builder = createBlockBuilder(f.mod);
		buildBuiltinBlock(f.builder);
		return f;
	}
}

unittest { // the builtin block alone already exercises most of the renderer
	auto f = makePrintFixture();
	scope(exit) freeModule(f.mod);
	immutable root = f.builder.end();

	// Namespaces, type definitions, pointers, function types (named and
	// unnamed parameters), valueless functions and calls are all in there.
	foreach (pretty; [false, true])
		foreach (debug_; [false, true])
			rendered(f.mod, root, pretty, debug_, (text_) {
				assert(text_.length > 0);
				assert(has(text_, "compiler"));
				assert(has(text_, "type.pointer("));  // `Pointer` with size 0
				assert(has(text_, "->"));             // a function type's return
				assert(has(text_, "namespace"));
			});

	// Pretty printing indents nested blocks; compact printing does not.
	rendered(f.mod, root, true, false, (text_) { assert(has(text_, "\n\t")); });
	rendered(f.mod, root, false, false, (text_) { assert(!has(text_, "\n")); });

	// Debug mode tags every entity with its id and spells lookups out.
	rendered(f.mod, root, true, true, (text_) { assert(has(text_, "[")); });
}

unittest { // a parsed-but-unlowered module renders its *unresolved* lookups
	diagnostics().clear();
	auto f = makePrintFixture();
	scope(exit) freeModule(f.mod);

	BlockBuilder* builders;
	scope(exit) fp.dynarray.free(builders);
	daPushBack(builders, f.builder);

	assert(parseSource(f.mod, builders,
		"n : compiler.byte = 5\n"
		~ "s : compiler.byte_pointer = \"hi\\n\"\n"
		~ "v : compiler.byte\n"
		~ "a : alias = n\n"
		~ "ns : namespace = {\n\tinner : compiler.byte = 1\n}\n"
		~ "t : type = {\n\tfield : compiler.byte\n}\n"
		~ "ft : type = (x: compiler.byte) -> compiler.byte\n"
		~ "blk : block = {\n\t%9 : compiler.byte = 2\n}\n"
		~ "c : compiler.byte = inline compiler.emit(n)\n",
		"print.doir"));
	assert(!diagnostics().hasErrors());
	immutable root = builders[0].block;

	rendered(f.mod, root, true, false, (text_) {
		assert(has(text_, "n: compiler.byte = 5"));
		assert(has(text_, "\"hi\\n\""));       // the string is re-escaped
		assert(has(text_, "v: compiler.byte")); // valueless: no ` = `
		assert(has(text_, "a: alias = n"));
		assert(has(text_, "ns: namespace = {"));
		assert(has(text_, "t: type = {"));
		assert(has(text_, "inline compiler.emit(n)"));
	});

	// In debug mode an unresolved lookup is spelled `lookup(name)`, and a
	// function definition is prefixed `f:`.
	rendered(f.mod, root, true, true, (text_) {
		assert(has(text_, "lookup("));
	});
	diagnostics().clear();
}

unittest { // a fully lowered module renders registers and comptime values
	auto r = compile(
		"u : alias = compiler.pointer_sized\n"
		~ "a : u = 5\n"
		~ "b : u = 6\n"
		~ "%1 : compiler.byte = compiler.emit(a)\n");
	scope(exit) freeModule(r.mod);
	assert(r.ok);

	// `debug_` is what prints the `[comp: ...]` and `[reg: ...]` annotations.
	rendered(r.mod, r.root, true, true, (text_) {
		assert(text_.length > 0);
		assert(has(text_, "[comp"));
	});
	rendered(r.mod, r.root, false, false, (text_) { assert(text_.length > 0); });
}

unittest { // every flag a call can carry is rendered back out
	diagnostics().clear();
	auto f = makePrintFixture();
	scope(exit) freeModule(f.mod);

	BlockBuilder* builders;
	scope(exit) fp.dynarray.free(builders);
	daPushBack(builders, f.builder);

	assert(parseSource(f.mod, builders,
		"n : compiler.byte = 1\n"
		~ "i : compiler.byte = inline compiler.emit(n)\n"
		~ "l : compiler.byte = flatten compiler.emit(n)\n"
		~ "t : compiler.byte = tail compiler.emit(n)\n",
		"flags.doir"));
	immutable root = builders[0].block;

	rendered(f.mod, root, true, false, (text_) {
		assert(has(text_, "inline "));
		assert(has(text_, "flatten "));
		assert(has(text_, "tail "));
	});
	diagnostics().clear();
}

unittest { // an array pointer prints as `type.array(base, size)`
	auto f = makePrintFixture();
	scope(exit) freeModule(f.mod);

	immutable byte_ = resolveLookupName(f.mod, internIn(f.mod, "compiler.byte"), f.builder.block);
	assert(byte_ != invalidEntity);
	pushPointer(f.builder, internIn(f.mod, "arr"), byte_, 16);

	rendered(f.mod, f.builder.end(), true, false, (text_) {
		assert(has(text_, "type.array("));
		assert(has(text_, ", 16)"));
	});
}

unittest { // an alias that names another file records the file in debug mode
	auto f = makePrintFixture();
	scope(exit) freeModule(f.mod);

	immutable byte_ = resolveLookupName(f.mod, internIn(f.mod, "compiler.byte"), f.builder.block);
	immutable e = pushAlias(f.builder, internIn(f.mod, "elsewhere"), byte_);
	auto a = &getComponent!Alias(f.mod, e);
	a.file = "other.doir";
	a.hasFile = true;

	rendered(f.mod, f.builder.end(), true, true, (text_) { assert(has(text_, "[other.doir]")); });
	// Without `debug_` the file is not shown.
	rendered(f.mod, f.builder.end(), true, false, (text_) { assert(!has(text_, "other.doir")); });
}

unittest { // ...and so does an unresolved one
	auto f = makePrintFixture();
	scope(exit) freeModule(f.mod);

	immutable e = pushAlias(f.builder, internIn(f.mod, "dangling"), internIn(f.mod, "nowhere"));
	auto a = &getComponent!LookupAlias(f.mod, e);
	a.file = "other.doir";
	a.hasFile = true;

	rendered(f.mod, f.builder.end(), true, true, (text_) {
		assert(has(text_, "dangling"));
		assert(has(text_, "[other.doir]"));
	});
}

unittest { // a `PrintAsCall` marker makes a substituted value print as its call
	auto f = makePrintFixture();
	scope(exit) freeModule(f.mod);

	immutable byte_ = resolveLookupName(f.mod, internIn(f.mod, "compiler.byte"), f.builder.block);
	immutable emit = resolveLookupName(f.mod, internIn(f.mod, "compiler.emit"), f.builder.block);
	immutable arg = pushNumber(f.builder, internIn(f.mod, "arg"), byte_, 1);

	immutable e = pushNumber(f.builder, internIn(f.mod, "substituted"), byte_, 7);
	addComponent!PrintAsCall(f.mod, e).related[0] = emit;
	auto inputs = &addComponent!FunctionInputs(f.mod, e);
	fp.dynarray.pushBack(inputs.related, arg);

	// Without `debug_` it renders as the call it came from...
	rendered(f.mod, f.builder.end(), true, false, (text_) {
		assert(has(text_, "substituted: compiler.byte = compiler.emit(arg)"));
	});
	// ...and with it, as the number it actually is.
	rendered(f.mod, f.builder.end(), true, true, (text_) { assert(has(text_, "= 7")); });
}

unittest { // the comptime annotations, one per component
	auto f = makePrintFixture();
	scope(exit) freeModule(f.mod);

	immutable byte_ = resolveLookupName(f.mod, internIn(f.mod, "compiler.byte"), f.builder.block);
	immutable n = pushNumber(f.builder, internIn(f.mod, "n"), byte_, 1);
	addComponent!ComptimeNumber(f.mod, n).value = 42;
	addComponent!AssignedRegister(f.mod, n).reg = 3;

	immutable s = pushString(f.builder, internIn(f.mod, "s"), byte_, internIn(f.mod, "text"));
	addComponent!ComptimeString(f.mod, s).value = internIn(f.mod, "text");

	// A `Comptime` flag with neither component attached prints the bare tag.
	immutable v = pushValueless(f.builder, internIn(f.mod, "v"), byte_);
	getOrAddComponent!Flags(f.mod, v).flags |= Flags.Comptime;

	rendered(f.mod, f.builder.end(), true, true, (text_) {
		assert(has(text_, "[comp: 42]"));
		assert(has(text_, "[comp: \"text\"]"));
		assert(has(text_, "[comp]"));
		assert(has(text_, "[reg: 3]"));
	});
}

unittest { // an entity carrying a location renders it after the value
	diagnostics().clear();
	auto f = makePrintFixture();
	scope(exit) freeModule(f.mod);

	BlockBuilder* builders;
	scope(exit) fp.dynarray.free(builders);
	daPushBack(builders, f.builder);

	// The `<file:line:col>` suffix attaches a `Detailed` directly; a plain
	// assignment gets a `SourceLocation` that is resolved on the way out.
	assert(parseSource(f.mod, builders,
		"x : compiler.byte = 1 <other.doir:3:4>\ny : compiler.byte = 2\n", "loc.doir"));
	assert(!diagnostics().hasErrors());

	rendered(f.mod, builders[0].block, true, false, (text_) {
		assert(has(text_, "other.doir"));
		assert(has(text_, "loc.doir"));
	});
	diagnostics().clear();
}

unittest { // IR the renderer has no shape for says so rather than crashing
	auto f = makePrintFixture();
	scope(exit) freeModule(f.mod);
	auto mod = &f.mod;

	// An entity with nothing on it at all.
	immutable bare = pushCommon(*mod, f.builder.block, internIn(*mod, "bare"));
	assert(bare != invalidEntity);

	// An entity with a `TypeOf` but no value of any kind behind it.
	immutable byte_ = resolveLookupName(*mod, internIn(*mod, "compiler.byte"), f.builder.block);
	immutable typed = pushCommon(*mod, f.builder.block, internIn(*mod, "typed"));
	addComponent!TypeOf(*mod, typed).related[0] = byte_;

	rendered(f.mod, f.builder.end(), true, false, (text_) {
		assert(has(text_, "<error>"));
		assert(has(text_, "<type_of error>"));
	});
}

unittest { // an unnamed entity prints as `%id`, and so does an unnamed lookup
	auto f = makePrintFixture();
	scope(exit) freeModule(f.mod);

	immutable byte_ = resolveLookupName(f.mod, internIn(f.mod, "compiler.byte"), f.builder.block);
	// `_` is the discard name, which `pushCommon` attaches no `Name` for.
	immutable anonymous = pushNumber(f.builder, InternedString("_"), byte_, 1);
	assert(!hasComponent!Name(f.mod, anonymous));

	immutable call = pushCall(f.builder, internIn(f.mod, "c"), byte_,
		resolveLookupName(f.mod, internIn(f.mod, "compiler.emit"), f.builder.block),
		(&anonymous)[0 .. 1]);
	assert(call != invalidEntity);

	rendered(f.mod, f.builder.end(), true, false, (text_) { assert(has(text_, "%")); });
}

unittest { // `printLookupName` renders a named entity, a path and a raw id
	auto f = makePrintFixture();
	scope(exit) freeModule(f.mod);
	immutable root = f.builder.end();

	// A namespaced name is qualified by walking up the parent chain.
	immutable byte_ = resolveLookupName(f.mod, internIn(f.mod, "compiler.byte"), root);
	char* qualified = printLookupName(f.mod, Lookup(byte_), false);
	scope(exit) strFree(qualified);
	assert(strSlice(qualified) == "compiler.byte");

	// In debug mode the entity id comes with it.
	char* withId = printLookupName(f.mod, Lookup(byte_), true);
	scope(exit) strFree(withId);
	assert(has(strSlice(withId), "compiler.byte["));

	// An unresolved lookup is its name, or `lookup(name)` in debug mode.
	char* plainName = printLookupName(f.mod, Lookup(internIn(f.mod, "unresolved")), false);
	scope(exit) strFree(plainName);
	assert(strSlice(plainName) == "unresolved");

	char* debugName = printLookupName(f.mod, Lookup(internIn(f.mod, "unresolved")), true);
	scope(exit) strFree(debugName);
	assert(strSlice(debugName) == "lookup(unresolved)");

	// An anonymous non-function entity is just `%id`.
	immutable anonymous = pushNumber(f.builder, InternedString("_"), byte_, 1);
	char* asId = printLookupName(f.mod, Lookup(anonymous), false);
	scope(exit) strFree(asId);
	assert(asId !is null && strSlice(asId)[0] == '%');
}

unittest { // an anonymous function type renders as its signature
	auto f = makePrintFixture();
	scope(exit) freeModule(f.mod);
	immutable root = f.builder.end();

	immutable byte_ = resolveLookupName(f.mod, internIn(f.mod, "compiler.byte"), root);
	Lookup[2] inputs = [Lookup(byte_), Lookup(byte_)];
	InternedString[2] names = [internIn(f.mod, "lhs"), internIn(f.mod, "rhs")];

	// With parameter names...
	immutable named = pushFunctionType(f.builder, InternedString("_"), inputs[], Lookup(byte_), true, names[]);
	char* withNames = printLookupName(f.mod, Lookup(named), false);
	scope(exit) strFree(withNames);
	assert(strSlice(withNames) == "(lhs:compiler.byte,rhs:compiler.byte)->compiler.byte");

	// ...and without, where they are numbered instead.
	immutable unnamed = pushFunctionType(f.builder, InternedString("_"), inputs[], Lookup(byte_), true);
	char* generated = printLookupName(f.mod, Lookup(unnamed), false);
	scope(exit) strFree(generated);
	assert(strSlice(generated) == "(a0:compiler.byte,a1:compiler.byte)->compiler.byte");

	// A function type with no return type at all stops after the parameters.
	Lookup[0] noInputs;
	immutable noReturn = pushFunctionType(f.builder, InternedString("_"), noInputs[], Lookup(byte_), false);
	char* nothing = printFunctionType(f.mod, noReturn, false);
	scope(exit) strFree(nothing);
	assert(strSlice(nothing) == "()");

	// In debug mode the type's own entity id is appended.
	char* debugged = printFunctionType(f.mod, named, true);
	scope(exit) strFree(debugged);
	assert(has(strSlice(debugged), "]"));
}

unittest { // `printModule` writes the same text to a FILE*
	auto f = makePrintFixture();
	scope(exit) freeModule(f.mod);
	immutable root = f.builder.end();

	auto file = tmpfile();
	assert(file !is null);
	scope(exit) fclose(file);
	printModule(file, f.mod, root, true, false);

	// Nothing to render writes nothing, and must not dereference the null.
	auto empty = createModule();
	scope(exit) freeModule(empty);
	immutable emptyRoot = createBlockBuilder(empty).end();
	printModule(file, empty, emptyRoot, true, false);
}

unittest {
	// `printSystem` writes to stdout, so this uses a module of its own with
	// two entities in it rather than one carrying the whole builtin block.
	import doir.pipeline.sema.sort : sort;

	auto mod = createModule();
	scope(exit) freeModule(mod);
	auto builder = createBlockBuilder(mod);
	pushNumber(builder, internIn(mod, "n"), internIn(mod, "u8"), 1);
	immutable root = builder.end();

	assert(printSystem(mod, root, true, false));

	// `currentCanonicalizeRoot` means "whatever `sort` last produced".
	sort(mod, root);
	assert(printSystem(mod, currentCanonicalizeRoot, false, true));
}

unittest { // a non-block root renders as the single entity it is
	auto f = makePrintFixture();
	scope(exit) freeModule(f.mod);
	immutable root = f.builder.end();

	immutable byte_ = resolveLookupName(f.mod, internIn(f.mod, "compiler.byte"), root);
	rendered(f.mod, byte_, true, false, (text_) { assert(text_.length > 0); });
}

unittest {
	// A function definition whose own type never resolved has no signature to
	// render, so the declared type name stands in for it and the body is
	// printed behind it.
	auto f = makePrintFixture();
	scope(exit) freeModule(f.mod);

	immutable byte_ = resolveLookupName(f.mod, internIn(f.mod, "compiler.byte"), f.builder.block);
	immutable e = pushCommon(f.mod, f.builder.block, internIn(f.mod, "pending"));
	addComponent!LookupTypeOf(f.mod, e).lookup = Lookup(internIn(f.mod, "nope"));
	addComponent!LookupFunctionReturnType(f.mod, e).lookup = Lookup(byte_);
	addComponent!Block(f.mod, e);

	rendered(f.mod, f.builder.end(), true, false, (text_) {
		assert(has(text_, "pending: nope = {"));
	});
}

unittest {
	// A function type reached through a type modification (`compiler.pointer`
	// and friends) is printed as the modification rather than unwrapped into a
	// parameter list.
	auto f = makePrintFixture();
	scope(exit) freeModule(f.mod);

	auto block = f.builder;
	immutable byte_ = resolveLookupName(f.mod, internIn(f.mod, "compiler.byte"), block.block);
	immutable emitT = resolveLookupName(f.mod, internIn(f.mod, "compiler.emit_t"), block.block);
	immutable pointer = resolveLookupName(f.mod, internIn(f.mod, "compiler.pointer"), block.block);
	assert(emitT != invalidEntity && pointer != invalidEntity);

	// `compiler.pointer(emit_t)` is a call `resolveTypeModifications` looks
	// through, so the entity below has a function type *behind* a modification.
	immutable modified = pushCall(block, internIn(f.mod, "modified"), byte_, pointer,
		(&emitT)[0 .. 1]);

	// With a body, so the parameter-list branch is the one that has to notice.
	immutable withBody = pushCommon(f.mod, block.block, internIn(f.mod, "with_body"));
	addComponent!TypeOf(f.mod, withBody).related[0] = modified;
	addComponent!FunctionReturnType(f.mod, withBody).related[0] = byte_;
	addComponent!Block(f.mod, withBody);

	// ...and without one, which is the valueless-function arm of the same test.
	immutable valueless = pushCommon(f.mod, block.block, internIn(f.mod, "valueless"));
	addComponent!TypeOf(f.mod, valueless).related[0] = modified;
	addComponent!FunctionReturnType(f.mod, valueless).related[0] = byte_;

	rendered(f.mod, block.end(), true, false, (text_) {
		assert(has(text_, "with_body: modified = {"));
		assert(has(text_, "valueless: modified"));
	});
}
