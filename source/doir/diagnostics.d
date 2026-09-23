/// The compiler's global diagnostic manager, the catalogue of diagnostics it
/// can emit, the little `(` ... `)` range scanner used to point an annotation
/// at a particular call argument, and `panic` for the failures that are not
/// diagnostics at all. Ported from diagnostics.hpp / diagnostics.cpp.
module doir.diagnostics;

import core.stdc.stdio : fprintf, stderr;
import core.stdc.stdlib : abort;

import diagnose.diagnostics : Ansi, Diagnostic, Kind, Manager, pushAnnotation;
import diagnose.source_location : Detailed, SourceLocation;

import ecrs.storage : EntityId;

import fp.string : strFree = free;
import std.typecons : Nullable;

import doir.interface_ : findDetailedSourceLocation, findSourceLocation;
import doir.string_helpers : appendText, text;
import doir.module_ : Module, sourceOf;

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

/// The stretch of `source` a location covers, clamped to what `source`
/// actually holds. A location and the text it is resolved against can still
/// drift apart - a synthesised location falls back to whatever file was
/// parsed last - and a diagnostic about that is worth printing wrong, but not
/// worth a bounds crash inside the error reporter.
const(char)[] spanOf(const(char)[] source, SourceLocation location) {
	immutable start = location.startByte < source.length ? location.startByte : source.length;
	immutable end = location.endByte < source.length ? location.endByte : source.length;
	return end > start ? source[start .. end] : null;
}

/// Finds the byte range of argument number `parameterIndex` inside the first
/// parenthesised argument list in `text_`, or null when there is no such
/// argument. Nested brackets are tracked so this keeps working for doir+'s
/// richer call syntax.
Nullable!Range parseParameterRange(const(char)[] text_, size_t parameterIndex) {
	size_t open = size_t.max;
	foreach (i; 0 .. text_.length)
		if (text_[i] == '(') { open = i; break; }
	if (open == size_t.max) return Nullable!Range.init;

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
					if (currentParameter == parameterIndex)
						return Nullable!Range(Range(parameterBegin, i));
					return Nullable!Range.init;
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
					if (currentParameter == parameterIndex)
						return Nullable!Range(Range(parameterBegin, i));
					++currentParameter;
					parameterBegin = i + 1;
				}
				break;

			default:
				break;
		}
	}

	return Nullable!Range.init;
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
	auto location = findDetailedSourceLocation(mod, subtree);
	auto diag = &pushDiagnostic(DiagnosticType.InvalidFunctionCall,
		location, sourceOf(mod, location), location.file);

	Diagnostic.Annotation annotation;
	annotation.message = text(DoirAnsi.func, name, Ansi.reset, " expects ", x, " inputs");
	annotation.position = diag.location.start;
	pushAnnotation(*diag, annotation);
}

/// `<name> parameter <i+1><msg>`, pointed at the middle of argument `i`.
void parameterError(ref Module mod, EntityId subtree, const(char)[] name, size_t i, const(char)[] msg) @trusted {
	auto location = findSourceLocation(mod, subtree);
	auto source = sourceOf(mod, location);
	auto diag = &pushDiagnostic(DiagnosticType.InvalidFunctionCall, location, source,
		location.file);

	Diagnostic.Annotation annotation;
	annotation.message = text(DoirAnsi.func, name, Ansi.reset, " parameter ",
		DoirAnsi.info, i + 1, Ansi.reset, msg);

	auto range = parseParameterRange(spanOf(source, location), i);
	if (!range.isNull)
		location.startByte += (range.get.start + range.get.end) / 2;
	annotation.position = location.start(source);
	pushAnnotation(*diag, annotation);
}

/// A diagnostic about the *contents* of a string constant, pointed `offset`
/// bytes into the text that constant holds.
///
/// For something handed to the compiler as text and then read by a parser of
/// its own - a schedule, so far - where the interesting position is somewhere
/// inside the string rather than anywhere in the call that was given it.
///
/// `offset` is into the string's value, and the caret goes that many bytes past
/// the literal's opening quote. Those are the same place for a raw (`"""`)
/// literal and for any literal that escapes nothing; where a literal does
/// escape something the caret lands that many bytes early, since the value is
/// shorter than the text that produced it. The message stays right either way,
/// which is why this is worth doing rather than printing a byte offset and
/// leaving the reader to count.
void stringContentsError(ref Module mod, EntityId stringEntity, char* message,
	size_t offset) @trusted
{
	auto location = findSourceLocation(mod, stringEntity);
	auto source = sourceOf(mod, location);
	auto diag = &pushDiagnostic(DiagnosticType.InvalidFunctionCall, location, source,
		location.file);

	// The entity's span covers its whole declaration (`name : type = "..."`),
	// so find where the literal starts inside it and step over the quote.
	auto span = spanOf(source, location);
	size_t quote = size_t.max;
	foreach (i; 0 .. span.length)
		if (span[i] == '"') { quote = i; break; }
	if (quote != size_t.max) {
		immutable raw = quote + 3 <= span.length
			&& span[quote + 1] == '"' && span[quote + 2] == '"';
		location.startByte += quote + (raw ? 3 : 1) + offset;
	}

	Diagnostic.Annotation annotation;
	annotation.message = message;
	annotation.position = location.start(source);
	pushAnnotation(*diag, annotation);
}

/// `Entity <target> doesn't have an associated register`.
void noAssociatedRegister(ref Module mod, EntityId subtree, EntityId target) @trusted {
	auto location = findDetailedSourceLocation(mod, subtree);
	auto diag = &pushDiagnostic(DiagnosticType.InvalidFunctionCall,
		location, sourceOf(mod, location), location.file);

	Diagnostic.Annotation annotation;
	annotation.message = text("Entity ", DoirAnsi.info, cast(size_t) target, Ansi.reset,
		" doesn't have an associated register");
	annotation.position = diag.location.start;
	pushAnnotation(*diag, annotation);
}

/// A plain single-annotation diagnostic anchored at the whole entity, which
/// several passes build by hand.
void simpleCallError(ref Module mod, EntityId subtree, char* message) @trusted {
	auto location = findDetailedSourceLocation(mod, subtree);
	auto diag = &pushDiagnostic(DiagnosticType.InvalidFunctionCall,
		location, sourceOf(mod, location), location.file);

	Diagnostic.Annotation annotation;
	annotation.message = message;
	annotation.position = diag.location.start;
	pushAnnotation(*diag, annotation);
}


// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest) {
	import ecrs.storage : invalidEntity;

	import fp.string : strFree = free, strSlice = slice;

	import doir.interface_;
	import doir.module_;
	import tests.pipeline_helper;
}

unittest { // `text` renders each piece type it accepts
	auto s = text("n=", cast(size_t) 42, " f=", 1.5L, " s=", "str");
	scope(exit) strFree(s);
	assert(strSlice(s) == "n=42 f=1.5 s=str");

	// A libfp string is a piece too, and a null one contributes nothing.
	char* inner = text("inner");
	scope(exit) strFree(inner);
	char* nested = text("[", inner, "]");
	scope(exit) strFree(nested);
	assert(strSlice(nested) == "[inner]");

	char* nothing = null;
	char* withNull = text("<", nothing, ">");
	scope(exit) strFree(withNull);
	assert(strSlice(withNull) == "<>");

	// `appendText` is the same thing onto an existing string.
	char* built = text("a");
	scope(exit) strFree(built);
	appendText(built, "b", cast(size_t) 1);
	assert(strSlice(built) == "ab1");
}

unittest { // every catalogued diagnostic has a message, and a kind
	static foreach (type; [
		DiagnosticType.LanguageChangeNotSupported, DiagnosticType.FileDoesNotExist,
		DiagnosticType.NumberingStartsAt1, DiagnosticType.NumberingOutOfOrder,
		DiagnosticType.AliasNotAllowed, DiagnosticType.InvalidIdentifier,
		DiagnosticType.InvalidType, DiagnosticType.InvalidFunctionCall,
		DiagnosticType.CantStoreInFunctionRegister, DiagnosticType.CantCopyRegisters,
		DiagnosticType.StringProcessingError, DiagnosticType.FailedToResolveLookup,
	]) {{
		auto diag = generateDiagnostic(type, Detailed.init, "", "t.doir");
		scope(exit) diagnostics().push(diag); // takes ownership of the message
		assert(diag.kind == Kind.error);
		assert(diag.hasCode && diag.code == cast(size_t) type);
		assert(diag.message !is null);
	}}
	assert(diagnostics().hasErrors());
	diagnostics().clear();

	auto warning = generateDiagnostic(DiagnosticType.CompilerNamespaceReserved,
		Detailed.init, "", "t.doir");
	diagnostics().push(warning);
	assert(warning.kind == Kind.warning);
	assert(!diagnostics().hasErrors());
	diagnostics().clear();

	// `Invalid` is not a diagnostic at all: it falls through with no message.
	auto invalid = generateDiagnostic(DiagnosticType.Invalid, Detailed.init, "", "t.doir");
	diagnostics().push(invalid);
	assert(invalid.message is null);
	diagnostics().clear();
}

unittest { // the byte-range overloads resolve their location against the source
	enum source = "x : compiler.byte = 1\n";
	auto diag = generateDiagnostic(DiagnosticType.InvalidType,
		SourceLocation("t.doir", 0, 1), source, "t.doir");
	diagnostics().push(diag);
	assert(diag.location.file == "t.doir");
	diagnostics().clear();

	pushDiagnostic(DiagnosticType.InvalidType, SourceLocation("t.doir", 0, 1), source, "t.doir");
	assert(diagnostics().count() == 1);
	diagnostics().clear();
}

unittest { // spanOf clamps a location to the text it is resolved against
	enum source = "abcdef";
	assert(spanOf(source, SourceLocation("t", 1, 4)) == "bcd");
	assert(spanOf(source, SourceLocation("t", 4, 99)) == "ef"); // end past the text
	assert(spanOf(source, SourceLocation("t", 99, 99)) is null); // start past it too
	assert(spanOf(source, SourceLocation("t", 3, 3)) is null);   // empty range
}

unittest { // parseParameterRange finds the nth argument of a call
	enum call = "f(a, bb, ccc)";

	auto first = parseParameterRange(call, 0);
	assert(call[first.get.start .. first.get.end] == "a");

	auto middle = parseParameterRange(call, 1);
	assert(call[middle.get.start .. middle.get.end] == " bb");

	auto last = parseParameterRange(call, 2);
	assert(call[last.get.start .. last.get.end] == " ccc");

	// Past the end of the list.
	assert(parseParameterRange("f(a, bb)", 5).isNull);

	// No argument list at all.
	assert(parseParameterRange("no call here", 0).isNull);
}

unittest { // ...and commas inside nested brackets do not separate arguments
	enum text_ = "f(g(a, b), [c, d], {e}, <h>, i)";

	auto nestedCall = parseParameterRange(text_, 0);
	assert(text_[nestedCall.get.start .. nestedCall.get.end] == "g(a, b)");

	auto square = parseParameterRange(text_, 1);
	assert(text_[square.get.start .. square.get.end] == " [c, d]");

	auto brace = parseParameterRange(text_, 2);
	assert(text_[brace.get.start .. brace.get.end] == " {e}");

	auto angle = parseParameterRange(text_, 3);
	assert(text_[angle.get.start .. angle.get.end] == " <h>");

	auto plain = parseParameterRange(text_, 4);
	assert(text_[plain.get.start .. plain.get.end] == " i");

	// An unbalanced closer at depth zero is ignored rather than underflowing.
	assert(parseParameterRange("f(a]b", 0).isNull);
}

unittest { // the recurring diagnostic shapes each push one annotated diagnostic
	diagnostics().clear();
	auto f = makeModuleWithBuiltins();
	scope(exit) freeModule(f.mod);

	auto block = BlockBuilder(f.root, &f.mod);
	immutable byte_ = resolveLookupName(f.mod, internIn(f.mod, "compiler.byte"), f.root);
	immutable emit = resolveLookupName(f.mod, internIn(f.mod, "compiler.emit"), f.root);
	immutable arg = pushNumber(block, internIn(f.mod, "arg"), byte_, 1);
	immutable call = pushCall(block, internIn(f.mod, "c"), byte_, emit, (&arg)[0 .. 1]);

	expectsXInputs(f.mod, call, "emit", "one");
	assert(diagnostics().count() == 1);

	parameterError(f.mod, call, "emit", 0, " is wrong");
	assert(diagnostics().count() == 2);

	noAssociatedRegister(f.mod, call, arg);
	assert(diagnostics().count() == 3);

	simpleCallError(f.mod, call, text("something went wrong"));
	assert(diagnostics().count() == 4);

	assert(diagnostics().hasErrors());
	diagnostics().clear();
}

unittest {
	// `parameterError` points at the middle of the argument it names, which it
	// finds by scanning the source text the entity's location covers - so this
	// one goes through a real parse rather than hand-built IR.
	diagnostics().clear();
	auto r = compile("a : compiler.byte = 1\nb : compiler.byte = compiler.emit(a)\n");
	scope(exit) freeModule(r.mod);
	assert(r.ok);

	immutable call = find(r.mod, r.root, "b");
	assert(call != invalidEntity);
	parameterError(r.mod, call, "emit", 0, " is wrong");
	assert(diagnostics().count() == 1);
	diagnostics().clear();
}
