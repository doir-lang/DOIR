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

	bool hasReturn;
	auto returnType = returnTypeOf(mod, type, hasReturn);

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

	if (hasReturn) {
		concatenateSlice(out_, "->");
		char* name = printLookupName(mod, returnType, debug_);
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
		out_.location = getComponent!SourceLocation(mod, subtree).toDetailed(mod.source);
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

				bool hasReturn;
				auto returnType = returnTypeOf(mod, ft, hasReturn);

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

					if (hasReturn) {
						concatenateSlice(out_, pretty ? " -> " : "->");
						char* name = printLookupName(mod, returnType, debug_);
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
