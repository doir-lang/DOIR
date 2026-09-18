/// The compiler's global diagnostic manager, the catalogue of diagnostics it
/// can emit, the little `(` ... `)` range scanner used to point an annotation
/// at a particular call argument, and `panic` for the failures that are not
/// diagnostics at all. Ported from diagnostics.hpp / diagnostics.cpp.
module doir.diagnostics;

import core.stdc.stdio : fprintf, snprintf, stderr;
import core.stdc.stdlib : abort;

import diagnose.diagnostics : Ansi, Diagnostic, Kind, Manager, pushAnnotation;
import diagnose.source_location : Detailed, SourceLocation;

import ecrs.storage : EntityId;

import fp.string : concatenateSlice, strFree = free;

import doir.interface_ : findDetailedSourceLocation, findSourceLocation;
import doir.module_ : Module, workingFileOr;

@nogc nothrow:


// ---------------------------------------------------------------------------
// Hard internal-consistency failures
// ---------------------------------------------------------------------------

/// Replacement for the `throw std::runtime_error("TODO: ...")` sites the C++
/// uses as hard internal-consistency failures.
///
/// Those throws are never caught anywhere in the C++ program, so reaching one
/// terminates the compiler after printing the message. `-betterC` has no
/// exceptions, so `panic` does exactly that - prints to stderr and aborts -
/// which keeps the observable behaviour of every such site unchanged.
///
/// Prints `message` (plus the source position it was raised from) and aborts.
noreturn panic(const(char)[] message, string file = __FILE__, size_t line = __LINE__) @trusted {
	fprintf(stderr, "doir: fatal: %.*s (%.*s:%zu)\n",
		cast(int) message.length, message.ptr,
		cast(int) file.length, file.ptr, line);
	abort();
	assert(0);
}


/// Stands in for a file name we never learned (the C++ `invalid_file_name`).
enum string invalidFileName = "<unknown>";

private __gshared Manager globalDiagnostics;

/// The process-wide diagnostic manager. The C++ version was a function-local
/// static; `-betterC` has no static constructors, and `Manager` is
/// zero-initialisable, so a plain `__gshared` does the same job.
ref Manager diagnostics() @trusted {
	return globalDiagnostics;
}

/// The colours DOIR paints particular kinds of thing in diagnostic text.
struct DoirAnsi {
	enum string info = Ansi.cyan; // == diagnose's colour for `Kind.info`
	enum string file = Ansi.magenta;
	enum string type = Ansi.cyan;
	enum string func = Ansi.blue;
}

enum DiagnosticType {
	Invalid,

	// Errors
	LanguageChangeNotSupported,
	FileDoesNotExist,
	NumberingStartsAt1,
	NumberingOutOfOrder,
	AliasNotAllowed,
	InvalidIdentifier,
	InvalidType,
	InvalidFunctionCall,
	CantStoreInFunctionRegister,
	CantCopyRegisters,
	StringProcessingError,
	FailedToResolveLookup,

	// Warnings
	CompilerNamespaceReserved,
}


// ---------------------------------------------------------------------------
// Small text helpers
// ---------------------------------------------------------------------------

/// Builds a freshly allocated libfp string out of `pieces`. Each piece is
/// either a `const(char)[]` or a `size_t` (rendered in decimal). The caller
/// frees the result with `fp.string.free`.
char* text(Args...)(Args pieces) @trusted {
	char* out_ = null;
	static foreach (p; pieces)
		appendPiece(out_, p);
	return out_;
}

/// Appends one piece to an existing libfp string.
void appendText(Args...)(ref char* out_, Args pieces) @trusted {
	static foreach (p; pieces)
		appendPiece(out_, p);
}

private void appendPiece(T)(ref char* out_, T piece) @trusted {
	static if (is(T : const(char)[])) {
		concatenateSlice(out_, piece);
	} else static if (is(T == char*) || is(T == const(char)*)) {
		import fp.string : strLength = length;
		if (piece !is null) concatenateSlice(out_, piece[0 .. strLength(piece)]);
	} else static if (is(T : real) && !is(T : long) && !is(T : ulong)) {
		char[64] buffer;
		immutable n = snprintf(buffer.ptr, buffer.length, "%Lg", cast(real) piece);
		if (n > 0) concatenateSlice(out_, buffer[0 .. n]);
	} else static if (is(T : long) || is(T : ulong)) {
		char[32] buffer;
		immutable n = snprintf(buffer.ptr, buffer.length, "%lld", cast(long) piece);
		if (n > 0) concatenateSlice(out_, buffer[0 .. n]);
	} else {
		static assert(0, "doir.diagnostics.text: unsupported piece type " ~ T.stringof);
	}
}


// ---------------------------------------------------------------------------
// Diagnostic construction
// ---------------------------------------------------------------------------

/// Builds (but does not push) the diagnostic for `type`, registering `source`
/// against `path` so the manager can render the offending line.
Diagnostic generateDiagnostic(DiagnosticType type, Detailed location, const(char)[] source, const(char)[] path) @trusted {
	diagnostics().registerSource(path, source);

	Diagnostic out_;
	out_.hasCode = true;
	out_.code = cast(size_t) type;
	out_.location = location;

	switch (type) {
		// Errors
		case DiagnosticType.LanguageChangeNotSupported:
			out_.kind = Kind.error;
			out_.message = text("Changing languages is not supported in the prototype");
			break;
		case DiagnosticType.FileDoesNotExist:
			out_.kind = Kind.error;
			out_.message = text("File does not exist");
			break;
		case DiagnosticType.NumberingStartsAt1:
			out_.kind = Kind.error;
			out_.message = text("Numbering starts at 1");
			break;
		case DiagnosticType.NumberingOutOfOrder:
			out_.kind = Kind.error;
			out_.message = text("Numbering out of order");
			break;
		case DiagnosticType.AliasNotAllowed:
			out_.kind = Kind.error;
			out_.message = text("Alias not allowed");
			break;
		case DiagnosticType.InvalidIdentifier:
			out_.kind = Kind.error;
			out_.message = text("Invalid identifier");
			break;
		case DiagnosticType.InvalidType:
			out_.kind = Kind.error;
			out_.message = text("Invalid type");
			break;
		case DiagnosticType.InvalidFunctionCall:
			out_.kind = Kind.error;
			out_.message = text("Invalid function call");
			break;
		case DiagnosticType.CantStoreInFunctionRegister:
			out_.kind = Kind.error;
			out_.message = text("Cannot store this value in a function register");
			break;
		case DiagnosticType.CantCopyRegisters:
			out_.kind = Kind.error;
			out_.message = text("Cannot directly ", DoirAnsi.info, "copy", Ansi.reset, " registers");
			break;
		case DiagnosticType.StringProcessingError:
			out_.kind = Kind.error;
			out_.message = text("Failed to process character string");
			break;
		case DiagnosticType.FailedToResolveLookup:
			out_.kind = Kind.error;
			out_.message = text("Failed to resolve lookup");
			break;

		// Warnings
		case DiagnosticType.CompilerNamespaceReserved:
			out_.kind = Kind.warning;
			out_.message = text("`compiler` namespace reserved");
			break;

		default:
			break;
	}

	return out_;
}

/// Ditto, from a byte-range location.
Diagnostic generateDiagnostic(DiagnosticType type, SourceLocation location, const(char)[] source, const(char)[] path) {
	return generateDiagnostic(type, location.toDetailed(source), source, path);
}

/// Builds the diagnostic for `type` and pushes it onto the global manager,
/// returning the pushed copy so the caller can hang annotations off it.
ref Diagnostic pushDiagnostic(DiagnosticType type, Detailed location, const(char)[] source, const(char)[] path) {
	return diagnostics().push(generateDiagnostic(type, location, source, path));
}

/// Ditto, from a byte-range location.
ref Diagnostic pushDiagnostic(DiagnosticType type, SourceLocation location, const(char)[] source, const(char)[] path) {
	return diagnostics().push(generateDiagnostic(type, location, source, path));
}


// ---------------------------------------------------------------------------
// Parameter range scanning
// ---------------------------------------------------------------------------

/// A half-open byte range within some text.
struct Range {
	size_t start, end;
}

/// Finds the byte range of argument number `parameterIndex` inside the first
/// parenthesised argument list in `text_`. `found` is false when there is no
/// such argument. Nested brackets are tracked so this keeps working for
/// doir+'s richer call syntax.
Range parseParameterRange(const(char)[] text_, size_t parameterIndex, out bool found) {
	found = false;

	size_t open = size_t.max;
	foreach (i; 0 .. text_.length)
		if (text_[i] == '(') { open = i; break; }
	if (open == size_t.max) return Range.init;

	size_t depth = 0;
	size_t currentParameter = 0;
	size_t parameterBegin = open + 1;

	for (size_t i = open + 1; i < text_.length; ++i) {
		immutable c = text_[i];

		switch (c) {
			case '(':
			case '[':
			case '{':
			case '<':
				++depth;
				break;

			case ')':
				if (depth == 0) {
					// Final parameter before ')'
					if (currentParameter == parameterIndex) {
						found = true;
						return Range(parameterBegin, i);
					}
					return Range.init;
				}
				--depth;
				break;

			case ']':
			case '}':
			case '>':
				if (depth > 0) --depth;
				break;

			case ',':
				if (depth == 0) {
					if (currentParameter == parameterIndex) {
						found = true;
						return Range(parameterBegin, i);
					}
					++currentParameter;
					parameterBegin = i + 1;
				}
				break;

			default:
				break;
		}
	}

	return Range.init;
}


// ---------------------------------------------------------------------------
// The recurring diagnostic shapes
// ---------------------------------------------------------------------------
//
// The diagnostics the semantic and optimisation passes raise over and over.
// Ported from sema/error_helper.hpp, where they were preprocessor macros;
// plain functions do the same job here. (They lived in their own
// `doir.pipeline.sema.error_helper` module for a while, but more than half their
// callers are `opt` passes, and every one of them is `pushDiagnostic` plus a
// single annotation - which is this module's job.)

/// `<name> expects <x> inputs`, pointed at the whole call.
void expectsXInputs(ref Module mod, EntityId subtree, const(char)[] name, const(char)[] x) @trusted {
	auto diag = &pushDiagnostic(DiagnosticType.InvalidFunctionCall,
		findDetailedSourceLocation(mod, subtree), mod.source, workingFileOr(mod, invalidFileName));

	Diagnostic.Annotation annotation;
	annotation.message = text(DoirAnsi.func, name, Ansi.reset, " expects ", x, " inputs");
	annotation.position = diag.location.start;
	pushAnnotation(*diag, annotation);
}

/// `<name> parameter <i+1><msg>`, pointed at the middle of argument `i`.
void parameterError(ref Module mod, EntityId subtree, const(char)[] name, size_t i, const(char)[] msg) @trusted {
	auto location = findSourceLocation(mod, subtree);
	auto diag = &pushDiagnostic(DiagnosticType.InvalidFunctionCall, location, mod.source,
		workingFileOr(mod, invalidFileName));

	Diagnostic.Annotation annotation;
	annotation.message = text(DoirAnsi.func, name, Ansi.reset, " parameter ",
		DoirAnsi.info, i + 1, Ansi.reset, msg);

	bool found;
	auto range = parseParameterRange(mod.source[location.startByte .. location.endByte], i, found);
	if (found)
		location.startByte += (range.start + range.end) / 2;
	annotation.position = location.start(mod.source);
	pushAnnotation(*diag, annotation);
}

/// `Entity <target> doesn't have an associated register`.
void noAssociatedRegister(ref Module mod, EntityId subtree, EntityId target) @trusted {
	auto diag = &pushDiagnostic(DiagnosticType.InvalidFunctionCall,
		findDetailedSourceLocation(mod, subtree), mod.source, workingFileOr(mod, invalidFileName));

	Diagnostic.Annotation annotation;
	annotation.message = text("Entity ", DoirAnsi.info, cast(size_t) target, Ansi.reset,
		" doesn't have an associated register");
	annotation.position = diag.location.start;
	pushAnnotation(*diag, annotation);
}

/// A plain single-annotation diagnostic anchored at the whole entity, which
/// several passes build by hand.
void simpleCallError(ref Module mod, EntityId subtree, char* message) @trusted {
	auto diag = &pushDiagnostic(DiagnosticType.InvalidFunctionCall,
		findDetailedSourceLocation(mod, subtree), mod.source, workingFileOr(mod, invalidFileName));

	Diagnostic.Annotation annotation;
	annotation.message = message;
	annotation.position = diag.location.start;
	pushAnnotation(*diag, annotation);
}
