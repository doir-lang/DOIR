/// The DOIR parser. Ported from parser.cpp + grammar.peg.
///
/// The C++ drove cpp-peglib from the PEG grammar and hung semantic actions off
/// each rule. There is no PEG engine among the three D dependencies, so this is
/// a hand-written recursive-descent parser with the same backtracking
/// discipline a PEG has: every rule is a function that either consumes input
/// and returns true, or restores `pos` and returns false, and every `/` is an
/// ordered choice tried left to right. Rule names and their order below mirror
/// grammar.peg one for one, so the two can be diffed against each other.
///
/// One deliberate approximation: `UnicodeIdentifierStart` /
/// `UnicodeIdentifierContinue` in the grammar are explicit (enormous) codepoint
/// tables. Here an identifier character is an ASCII letter/digit/underscore, or
/// any non-ASCII codepoint that isn't one of the Unicode spaces the `_` rule
/// lists. That accepts everything the tables do plus a handful of non-ASCII
/// symbols they exclude.
module doir.parser;

import core.stdc.stdio : snprintf;

import diagnose.diagnostics : Ansi, Diagnostic, Kind, Manager, pushAnnotation, pushAnnotationAtStart;
import diagnose.source_location : Detailed, Pair, SourceLocation;
import ecrs.storage : EntityId, invalidEntity;

static import fp.dynarray;
import fp.dynarray : daBack = back, daLength = length;
import fp.string : strFree = free, strSlice = slice;

import doir.diagnostics;
import doir.file_manager : getFileString;
import doir.interface_;
import doir.module_;
import doir.string_helpers;
import doir.verify : identifierStructure;

@nogc nothrow:


// ---------------------------------------------------------------------------
// Parsed value shapes (the C++ `assignment_value_t` variant and friends)
// ---------------------------------------------------------------------------

enum ValueKind {
	none,
	number,
	str,
	call,
	block,
	functionType,
}

/// `flatten`/`inline`/`tail` plus the callee and its arguments.
struct CallInfo {
	bool flatten, inline_, tail;
	InternedString function_;
	LookupList inputs;

	@nogc nothrow:
	void free() { inputs.free(); }
}

/// One declared parameter of a function type.
struct FunctionTypeParam {
	InternedString name;
	Lookup type;
	ValueKind valueKind = ValueKind.none;
	real number = 0;
	InternedString str;
}

/// A parsed `(a: T, b: U) -> V`.
struct FunctionTypeT {
	FunctionTypeParam* params = null; // fp dynarray
	bool hasReturnType = false;
	Lookup returnType;

	@nogc nothrow:
	void free() @trusted { if (params !is null) { fp.dynarray.free(params); params = null; } }
	size_t length() const @trusted { return daLength(cast(FunctionTypeParam*) params); }
}

/// Either a resolved-by-name type (`lookup::type_of`) or a function type.
struct ParsedType {
	bool isFunctionType = false;
	InternedString name;     // when !isFunctionType
	FunctionTypeT functionType;

	@nogc nothrow:
	void free() { functionType.free(); }
}

/// The right-hand side of an assignment.
struct ParsedValue {
	ValueKind kind = ValueKind.none;
	real number = 0;
	InternedString str;
	CallInfo call;
	EntityId block;
	FunctionTypeT functionType;

	@nogc nothrow:
	void free() { call.free(); functionType.free(); }
}


// ---------------------------------------------------------------------------
// Parser state
// ---------------------------------------------------------------------------

struct Parser {
	Module* mod;
	const(char)[] source;
	const(char)[] path;
	size_t pos;
	bool guaranteeSourceLocation = true;
	size_t furthest; // deepest byte offset reached, for the syntax-error report
}

private bool eof(ref Parser p) { return p.pos >= p.source.length; }
private char peek(ref Parser p) { return p.pos < p.source.length ? p.source[p.pos] : '\0'; }

private void advance(ref Parser p, size_t n = 1) {
	p.pos += n;
	if (p.pos > p.furthest) p.furthest = p.pos;
}

private bool literal(ref Parser p, const(char)[] text_) @trusted {
	if (p.pos + text_.length > p.source.length) return false;
	foreach (i; 0 .. text_.length)
		if (p.source[p.pos + i] != text_[i]) return false;
	advance(p, text_.length);
	return true;
}

private bool lookingAt(ref Parser p, const(char)[] text_) @trusted {
	if (p.pos + text_.length > p.source.length) return false;
	foreach (i; 0 .. text_.length)
		if (p.source[p.pos + i] != text_[i]) return false;
	return true;
}


// ---------------------------------------------------------------------------
// Character classes
// ---------------------------------------------------------------------------

private bool isDigit(char c) { return c >= '0' && c <= '9'; }
private bool isOctalDigit(char c) { return c >= '0' && c <= '7'; }
private bool isHexDigit(char c) {
	return isDigit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
}
private bool isAsciiAlpha(char c) {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
}

/// Decodes one UTF-8 codepoint at `i`, advancing it. Malformed bytes are
/// returned as themselves so the parser can never stall.
private uint decodeAt(const(char)[] s, ref size_t i) @trusted {
	immutable c = cast(ubyte) s[i];
	if (c < 0x80) { ++i; return c; }
	if ((c >> 5) == 0x6 && i + 1 < s.length) {
		immutable cp = ((c & 0x1F) << 6) | (cast(ubyte) s[i + 1] & 0x3F);
		i += 2; return cp;
	}
	if ((c >> 4) == 0xE && i + 2 < s.length) {
		immutable cp = ((c & 0x0F) << 12) | ((cast(ubyte) s[i + 1] & 0x3F) << 6)
			| (cast(ubyte) s[i + 2] & 0x3F);
		i += 3; return cp;
	}
	if ((c >> 3) == 0x1E && i + 3 < s.length) {
		immutable cp = ((c & 0x07) << 18) | ((cast(ubyte) s[i + 1] & 0x3F) << 12)
			| ((cast(ubyte) s[i + 2] & 0x3F) << 6) | (cast(ubyte) s[i + 3] & 0x3F);
		i += 4; return cp;
	}
	++i;
	return c;
}

/// The Unicode spaces the grammar's `_` rule lists (beyond plain ASCII ones).
private bool isUnicodeSpace(uint cp) {
	switch (cp) {
		case 0x85, 0xA0, 0x2007, 0x2028, 0x2029, 0x202F, 0x205F, 0x1680, 0x3000:
			return true;
		default:
			return (cp >= 0x2000 && cp <= 0x2006) || (cp >= 0x2008 && cp <= 0x200A);
	}
}

private bool isAsciiSpace(char c, bool includeNewlines) {
	switch (c) {
		case ' ', '\t', '\v', '\f': return true;
		case '\n', '\r': return includeNewlines;
		default: return false;
	}
}

/// `LongComment <- '/*' (!'*/'.)* '*/'` and `LineComment <- ('//' | '#') (!'\n' .)*`
private bool comment(ref Parser p) {
	if (lookingAt(p, "/*")) {
		advance(p, 2);
		while (!eof(p) && !lookingAt(p, "*/")) advance(p);
		if (lookingAt(p, "*/")) advance(p, 2);
		return true;
	}
	if (lookingAt(p, "//") || peek(p) == '#') {
		advance(p, lookingAt(p, "//") ? 2 : 1);
		while (!eof(p) && peek(p) != '\n') advance(p);
		return true;
	}
	return false;
}

/// `_` - whitespace (newlines included) and comments.
private void skipWhitespace(ref Parser p) {
	skipSpacing(p, true);
}

/// `wsc` - whitespace *without* newlines, and comments.
private void skipWsc(ref Parser p) {
	skipSpacing(p, false);
}

private void skipSpacing(ref Parser p, bool includeNewlines) @trusted {
	for (;;) {
		if (eof(p)) return;
		immutable c = peek(p);
		if (isAsciiSpace(c, includeNewlines)) { advance(p); continue; }
		if (cast(ubyte) c >= 0x80) {
			size_t probe = p.pos;
			immutable cp = decodeAt(p.source, probe);
			if (isUnicodeSpace(cp)) { advance(p, probe - p.pos); continue; }
			return;
		}
		if (comment(p)) continue;
		return;
	}
}

/// True if the codepoint starting at `i` may begin an identifier.
private bool identifierStartAt(ref Parser p, size_t i, out size_t width) @trusted {
	if (i >= p.source.length) { width = 0; return false; }
	immutable c = p.source[i];
	if (isAsciiAlpha(c) || c == '_') { width = 1; return true; }
	if (cast(ubyte) c < 0x80) { width = 0; return false; }
	size_t probe = i;
	immutable cp = decodeAt(p.source, probe);
	width = probe - i;
	return !isUnicodeSpace(cp);
}

/// True if the codepoint starting at `i` may continue an identifier.
private bool identifierContinueAt(ref Parser p, size_t i, out size_t width) @trusted {
	if (i >= p.source.length) { width = 0; return false; }
	immutable c = p.source[i];
	if (isAsciiAlpha(c) || isDigit(c) || c == '_') { width = 1; return true; }
	if (cast(ubyte) c < 0x80) { width = 0; return false; }
	size_t probe = i;
	immutable cp = decodeAt(p.source, probe);
	width = probe - i;
	return !isUnicodeSpace(cp);
}


// ---------------------------------------------------------------------------
// Diagnostics helpers
// ---------------------------------------------------------------------------

/// The C++ `get_location(mod, vs)`: the span a rule consumed, with trailing
/// whitespace trimmed back off.
private SourceLocation spanLocation(ref Parser p, size_t start, size_t end) @trusted {
	auto mod = p.mod;
	while (end > start) {
		immutable c = p.source[end - 1];
		if (c == '\n' || c == '\r' || isAsciiSpace(c, true)) --end;
		else break;
	}
	return SourceLocation(p.path, start, end);
}

/// Interns `text` after unescaping it, reporting any escape error against the
/// span `start .. end` (the C++ `escape_string` lambda).
private InternedString escapeString(ref Parser p, const(char)[] text_, size_t start, size_t end) @trusted {
	auto mod = p.mod;
	StringProcessingError err;
	char* unescaped = unescapePythonString(text_, err);
	scope(exit) strFree(unescaped);

	if (!err.failed)
		return internIn(*mod, unescaped is null ? "" : strSlice(unescaped));

	auto sourceLocation = spanLocation(p, start, end);
	auto diag = &pushDiagnostic(DiagnosticType.StringProcessingError, sourceLocation, mod.source, p.path);
	Diagnostic.Annotation annotation;
	annotation.message = text(err.message);
	sourceLocation.startByte += err.start;
	sourceLocation.endByte = sourceLocation.startByte + 1;
	annotation.position = sourceLocation.toDetailed(mod.source).start;
	pushAnnotation(*diag, annotation);
	return internIn(*mod, "<error>");
}


// ---------------------------------------------------------------------------
// Lexical rules
// ---------------------------------------------------------------------------

/// `StringChar <- (!['"\n\\] .) / ('\\' ...) ...`
private bool stringChar(ref Parser p) @trusted {
	if (eof(p)) return false;
	immutable c = peek(p);

	if (c == '\\') {
		immutable save = p.pos;
		advance(p);
		if (eof(p)) { p.pos = save; return false; }
		immutable e = peek(p);
		if (e == '\'' || e == '"' || e == '?' || e == '\\' || e == '%'
			|| e == 'a' || e == 'b' || e == 'f' || e == 'n' || e == 'r' || e == 't' || e == 'v')
		{
			advance(p);
			return true;
		}
		if (isOctalDigit(e)) {
			while (!eof(p) && isOctalDigit(peek(p))) advance(p);
			return true;
		}
		if (e == 'x') {
			advance(p);
			if (eof(p) || !isHexDigit(peek(p))) { p.pos = save; return false; }
			while (!eof(p) && isHexDigit(peek(p))) advance(p);
			return true;
		}
		if (e == 'u' || e == 'U') {
			immutable want = e == 'u' ? 4 : 8;
			advance(p);
			foreach (_; 0 .. want) {
				if (eof(p) || !isHexDigit(peek(p))) { p.pos = save; return false; }
				advance(p);
			}
			return true;
		}
		p.pos = save;
		return false;
	}

	if (c == '\'' || c == '"' || c == '\n') return false;
	advance(p);
	return true;
}

/// `IntegerConstant <- ('0x' HexDigit+) / ('0b' [01]*) / ('0' [0-7]*) / ([1-9][0-9]*)`
private bool integerConstant(ref Parser p) {
	immutable save = p.pos;

	if (lookingAt(p, "0x") || lookingAt(p, "0X")) {
		advance(p, 2);
		if (eof(p) || !isHexDigit(peek(p))) { p.pos = save; return false; }
		while (!eof(p) && isHexDigit(peek(p))) advance(p);
		return true;
	}
	if (lookingAt(p, "0b") || lookingAt(p, "0B")) {
		advance(p, 2);
		while (!eof(p) && (peek(p) == '0' || peek(p) == '1')) advance(p);
		return true;
	}
	if (peek(p) == '0') {
		advance(p);
		while (!eof(p) && isOctalDigit(peek(p))) advance(p);
		return true;
	}
	if (peek(p) >= '1' && peek(p) <= '9') {
		advance(p);
		while (!eof(p) && isDigit(peek(p))) advance(p);
		return true;
	}
	return false;
}

/// `FloatConstant <- ('0x' (HexDigit* '.' HexDigit+ / HexDigit+ '.'?) ([pP][+-]?[0-9]+)?)
///                 / (([0-9]* '.' [0-9]+ / [0-9]+ '.'?) ('e'i[+-]?[0-9]+)?)`
private bool floatConstant(ref Parser p) {
	immutable save = p.pos;

	if (lookingAt(p, "0x") || lookingAt(p, "0X")) {
		advance(p, 2);
		immutable mantissaStart = p.pos;
		// HexDigit* '.' HexDigit+
		while (!eof(p) && isHexDigit(peek(p))) advance(p);
		if (peek(p) == '.') {
			advance(p);
			if (eof(p) || !isHexDigit(peek(p))) {
				// Fall back to the second alternative: HexDigit+ '.'?
				p.pos = mantissaStart;
				if (eof(p) || !isHexDigit(peek(p))) { p.pos = save; return false; }
				while (!eof(p) && isHexDigit(peek(p))) advance(p);
				if (peek(p) == '.') advance(p);
			} else {
				while (!eof(p) && isHexDigit(peek(p))) advance(p);
			}
		} else if (p.pos == mantissaStart) {
			p.pos = save;
			return false;
		}
		if (peek(p) == 'p' || peek(p) == 'P') {
			immutable expSave = p.pos;
			advance(p);
			if (peek(p) == '+' || peek(p) == '-') advance(p);
			if (eof(p) || !isDigit(peek(p))) p.pos = expSave;
			else while (!eof(p) && isDigit(peek(p))) advance(p);
		}
		return true;
	}

	// [0-9]* '.' [0-9]+
	{
		immutable alt = p.pos;
		while (!eof(p) && isDigit(peek(p))) advance(p);
		if (peek(p) == '.') {
			advance(p);
			if (!eof(p) && isDigit(peek(p))) {
				while (!eof(p) && isDigit(peek(p))) advance(p);
				goto exponent;
			}
		}
		p.pos = alt;
	}
	// [0-9]+ '.'?
	if (eof(p) || !isDigit(peek(p))) { p.pos = save; return false; }
	while (!eof(p) && isDigit(peek(p))) advance(p);
	if (peek(p) == '.') advance(p);

exponent:
	if (peek(p) == 'e' || peek(p) == 'E') {
		immutable expSave = p.pos;
		advance(p);
		if (peek(p) == '+' || peek(p) == '-') advance(p);
		if (eof(p) || !isDigit(peek(p))) p.pos = expSave;
		else while (!eof(p) && isDigit(peek(p))) advance(p);
	}
	return true;
}

/// `Keywords <- ('deduced' | 'export' | 'flatten' | 'inline' | 'language' | 'tail')_`
private bool atKeyword(ref Parser p) {
	static immutable string[6] keywords = ["deduced", "export", "flatten", "inline", "language", "tail"];
	foreach (k; keywords)
		if (lookingAt(p, k)) return true;
	return false;
}

/// `Identifier <- "%" ('"' < StringChar* > '"') / !Keywords < ([%]/UnicodeIdentifierStart)([.]/UnicodeIdentifierContinue)* >`
private bool identifier(ref Parser p, out InternedString result) @trusted {
	immutable save = p.pos;
	auto mod = p.mod;

	// Choice 0: %"..."
	if (peek(p) == '%' && p.pos + 1 < p.source.length && p.source[p.pos + 1] == '"') {
		advance(p, 2);
		immutable contentStart = p.pos;
		while (stringChar(p)) {}
		immutable contentEnd = p.pos;
		if (peek(p) != '"') { p.pos = save; return false; }
		advance(p);
		// TODO: Are there later identifier verifies which need to be aware
		// that this is a special snowflake?
		result = escapeString(p, p.source[contentStart .. contentEnd], save, p.pos);
		return true;
	}

	// Choice 1: !Keywords <start continue*>
	if (atKeyword(p)) return false;

	size_t width;
	if (peek(p) == '%') width = 1;
	else if (!identifierStartAt(p, p.pos, width)) return false;
	advance(p, width);

	for (;;) {
		if (peek(p) == '.') { advance(p); continue; }
		if (!identifierContinueAt(p, p.pos, width)) break;
		advance(p, width);
	}

	result = internIn(*mod, p.source[save .. p.pos]);
	identifierStructure(diagnostics(), *mod, result);
	return true;
}


// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// Parses `Constant`, filling `value`. The choice order is the grammar's:
/// float, integer, string, char - which means a plain `1234` is matched by
/// `FloatConstant`, exactly as in the original.
private bool constant(ref Parser p, ref ParsedValue value) @trusted {
	immutable save = p.pos;

	if (floatConstant(p)) {
		value.kind = ValueKind.number;
		value.number = tokenToNumber(p.source[save .. p.pos]);
		return true;
	}
	if (integerConstant(p)) {
		value.kind = ValueKind.number;
		value.number = tokenToNumber(p.source[save .. p.pos]);
		return true;
	}
	if (peek(p) == '"') {
		advance(p);
		immutable contentStart = p.pos;
		while (stringChar(p)) {}
		immutable contentEnd = p.pos;
		if (peek(p) != '"') { p.pos = save; return false; }
		advance(p);
		value.kind = ValueKind.str;
		value.str = escapeString(p, p.source[contentStart .. contentEnd], save, p.pos);
		return true;
	}
	if (peek(p) == '\'') {
		advance(p);
		immutable contentStart = p.pos;
		if (!stringChar(p)) { p.pos = save; return false; }
		immutable contentEnd = p.pos;
		if (peek(p) != '\'') { p.pos = save; return false; }
		advance(p);
		value.kind = ValueKind.str;
		value.str = escapeString(p, p.source[contentStart .. contentEnd], save, p.pos);
		return true;
	}

	return false;
}

/// The C++ `vs.token_to_number<long double>()`, plus its `== 0` fallback to
/// `std::stoi(token, nullptr, 0)` which is what actually decodes `0x...`
/// (and, as there, leaves `0b...` reading as plain `0`).
private real tokenToNumber(const(char)[] token) @trusted {
	import core.stdc.stdlib : strtol, strtold;

	import core.stdc.string : memcpy;
	char[64] buffer;
	immutable n = token.length < buffer.length - 1 ? token.length : buffer.length - 1;
	if (n) memcpy(buffer.ptr, token.ptr, n);
	buffer[n] = '\0';

	real value = strtold(buffer.ptr, null);
	if (value != 0) return value;

	// Base 0: decimal, 0x hex, leading-0 octal.
	return cast(real) strtol(buffer.ptr, null, 0);
}


// ---------------------------------------------------------------------------
// SourceInfo
// ---------------------------------------------------------------------------

private size_t tokenToSize(const(char)[] token) @trusted {
	import core.stdc.stdlib : strtoull;
	import core.stdc.string : memcpy;
	char[32] buffer;
	immutable n = token.length < buffer.length - 1 ? token.length : buffer.length - 1;
	if (n) memcpy(buffer.ptr, token.ptr, n);
	buffer[n] = '\0';
	return cast(size_t) strtoull(buffer.ptr, null, 10);
}

/// `SourceInfo <- ('<"' <(!'"' .)*> '":' / '<' <(!':' .)*> ':')
///                <IntegerConstant> (<'-' IntegerConstant>)? ':'
///                <IntegerConstant> (<'-' IntegerConstant>)? '>'`
private bool sourceInfo(ref Parser p, out Detailed result) @trusted {
	immutable save = p.pos;
	auto mod = p.mod;

	const(char)[] file;
	if (lookingAt(p, "<\"")) {
		advance(p, 2);
		immutable start = p.pos;
		while (!eof(p) && peek(p) != '"') advance(p);
		file = p.source[start .. p.pos];
		if (!literal(p, "\":")) { p.pos = save; return false; }
	} else if (peek(p) == '<') {
		advance(p);
		immutable start = p.pos;
		while (!eof(p) && peek(p) != ':') advance(p);
		file = p.source[start .. p.pos];
		if (peek(p) != ':') { p.pos = save; return false; }
		advance(p);
	} else return false;

	size_t startLine, endLine, startColumn, endColumn;
	bool hasEndLine, hasEndColumn;

	{
		immutable t = p.pos;
		if (!integerConstant(p)) { p.pos = save; return false; }
		startLine = tokenToSize(p.source[t .. p.pos]);
	}
	if (peek(p) == '-') {
		immutable t = p.pos;
		advance(p);
		if (!integerConstant(p)) { p.pos = t; }
		else { endLine = tokenToSize(p.source[t + 1 .. p.pos]); hasEndLine = true; }
	}
	if (peek(p) != ':') { p.pos = save; return false; }
	advance(p);
	{
		immutable t = p.pos;
		if (!integerConstant(p)) { p.pos = save; return false; }
		startColumn = tokenToSize(p.source[t .. p.pos]);
	}
	if (peek(p) == '-') {
		immutable t = p.pos;
		advance(p);
		if (!integerConstant(p)) { p.pos = t; }
		else { endColumn = tokenToSize(p.source[t + 1 .. p.pos]); hasEndColumn = true; }
	}
	if (peek(p) != '>') { p.pos = save; return false; }
	advance(p);

	result.file = file;
	result.start.line = startLine;
	if (!hasEndLine) result.end.line = startLine;
	else result.end.line = endLine;
	result.start.column = startColumn;
	if (!hasEndColumn) result.end.column = startColumn + 1;
	else result.end.column = endColumn;

	auto span = spanLocation(p, save, p.pos);

	if (result.end.line < result.start.line || result.end.column < result.start.column) {
		auto diag = &pushDiagnostic(DiagnosticType.NumberingOutOfOrder, span, mod.source, p.path);
		size_t offset = findColon(p.source[save .. p.pos], 0);
		if (!(result.end.line < result.start.line))
			offset = findColon(p.source[save .. p.pos], offset + 1);

		Diagnostic.Annotation annotation;
		annotation.position = Pair(diag.location.start.line, diag.location.start.column + offset + 1);
		annotation.message = text("The ", DoirAnsi.info, "start", Ansi.reset,
			" of a source location must come before its ", DoirAnsi.info, "end", Ansi.reset);
		annotation.color = DoirAnsi.info;
		pushAnnotation(*diag, annotation);
	}

	if (result.start.column == 0 && result.end.column == 1 && result.start.line != 0) {
		bool ok;
		auto contents = getFileString(result.file, ok);
		if (ok) {
			result.start.column = 1;
			result.end.column = lineLength(contents, result.start.line - 1) + 1;
		} else {
			auto diag = &pushDiagnostic(DiagnosticType.FileDoesNotExist, span, mod.source, p.path);
			Diagnostic.Annotation annotation;
			annotation.message = text("Attempted to load file ", DoirAnsi.file, "`",
				result.file, "`", Ansi.reset);
			annotation.color = DoirAnsi.file;
			pushAnnotationAtStart(*diag, annotation);
			diag.additionalNote = text(
				"Calculating the end of line with column=0 requires loading a file and scanning its lines.");
		}
	} else if (result.start.column == 0 || result.start.line == 0) {
		auto diag = &pushDiagnostic(DiagnosticType.NumberingStartsAt1, span, mod.source, p.path);
		immutable line = result.start.line == 0;
		size_t offset = findColon(p.source[save .. p.pos], 0);
		if (!line) offset = findColon(p.source[save .. p.pos], offset + 1);

		Diagnostic.Annotation annotation;
		annotation.position = Pair(diag.location.start.line, diag.location.start.column + offset + 1);
		annotation.message = text("Source location ", DoirAnsi.info, line ? "lines" : "columns",
			Ansi.reset, " start at 0, not 1");
		annotation.color = DoirAnsi.info;
		pushAnnotation(*diag, annotation);
	}

	return true;
}

private size_t findColon(const(char)[] s, size_t from) {
	foreach (i; from .. s.length)
		if (s[i] == ':') return i;
	return size_t.max;
}

private size_t lineLength(const(char)[] contents, size_t index) {
	size_t line = 0, start = 0;
	foreach (i; 0 .. contents.length) {
		if (contents[i] == '\n') {
			if (line == index) return i - start;
			++line;
			start = i + 1;
		}
	}
	return line == index ? contents.length - start : 0;
}


// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/// `Type <- FunctionType / Identifier`
private bool type(ref Parser p, ref BlockBuilder* blocks, ref ParsedType result) {
	if (functionType(p, blocks, result.functionType)) {
		result.isFunctionType = true;
		return true;
	}
	InternedString name;
	if (!identifier(p, name)) return false;
	result.isFunctionType = false;
	result.name = name;
	return true;
}

/// `deducible_type <- (<'deduced'>_)? Type _`
private bool deducibleType(ref Parser p, ref BlockBuilder* blocks, ref ParsedType result) @trusted {
	immutable save = p.pos;
	auto mod = p.mod;

	bool deduced = false;
	if (lookingAt(p, "deduced")) {
		advance(p, "deduced".length);
		skipWhitespace(p);
		deduced = true;
	}

	if (!type(p, blocks, result)) { p.pos = save; return false; }
	skipWhitespace(p);

	if (deduced) {
		auto diag = &pushDiagnostic(DiagnosticType.InvalidType, spanLocation(p, save, p.pos),
			mod.source, p.path);
		Diagnostic.Annotation annotation;
		annotation.message = text(DoirAnsi.type, "Deducible", Ansi.reset, " types not yet supported");
		annotation.position = diag.location.start;
		pushAnnotation(*diag, annotation);
	}
	return true;
}

/// `parameter <- Identifier _ ':'_ deducible_type ('='_ Constant _)?`
private bool parameter(ref Parser p, ref BlockBuilder* blocks, ref FunctionTypeParam result) @trusted {
	immutable save = p.pos;

	if (!identifier(p, result.name)) return false;
	skipWhitespace(p);
	if (peek(p) != ':') { p.pos = save; return false; }
	advance(p);
	skipWhitespace(p);

	ParsedType paramType;
	if (!deducibleType(p, blocks, paramType)) { p.pos = save; return false; }

	if (paramType.isFunctionType) {
		immutable e = pushFunctionTypeEntity(p, blocks, paramType.functionType, InternedString("_"));
		paramType.free();
		result.type = Lookup(e);
	} else {
		result.type = Lookup(paramType.name);
	}

	if (peek(p) == '=') {
		immutable defaultSave = p.pos;
		advance(p);
		skipWhitespace(p);
		ParsedValue value;
		if (constant(p, value)) {
			skipWhitespace(p);
			result.valueKind = value.kind;
			result.number = value.number;
			result.str = value.str;
		} else p.pos = defaultSave;
	}

	return true;
}

/// `FunctionType <- '('_ (parameter (','_ parameter)*)? ')' _ <'->'>_ Type`
private bool functionType(ref Parser p, ref BlockBuilder* blocks, ref FunctionTypeT result) @trusted {
	immutable save = p.pos;

	if (peek(p) != '(') return false;
	advance(p);
	skipWhitespace(p);

	FunctionTypeParam first;
	if (parameter(p, blocks, first)) {
		fp.dynarray.pushBack(result.params, first);
		for (;;) {
			immutable commaSave = p.pos;
			if (peek(p) != ',') break;
			advance(p);
			skipWhitespace(p);
			FunctionTypeParam next;
			if (!parameter(p, blocks, next)) { p.pos = commaSave; break; }
			fp.dynarray.pushBack(result.params, next);
		}
	}

	if (peek(p) != ')') { result.free(); p.pos = save; return false; }
	advance(p);
	skipWhitespace(p);
	if (!literal(p, "->")) { result.free(); p.pos = save; return false; }
	skipWhitespace(p);

	ParsedType returnType;
	if (!type(p, blocks, returnType)) { result.free(); p.pos = save; return false; }

	result.hasReturnType = true;
	if (returnType.isFunctionType) {
		// NOTE: the C++ `any_cast<ecrs::entity_t>` here would throw on a
		// function-type return type (the value it holds is a `function_type_t`).
		// Materialising it into an entity is what that cast was reaching for,
		// and is what the sibling `parameter` handler already does.
		immutable e = pushFunctionTypeEntity(p, blocks, returnType.functionType, InternedString("_"));
		returnType.free();
		result.returnType = Lookup(e);
	} else {
		result.returnType = Lookup(returnType.name);
	}

	return true;
}

/// The C++ `function_type_t::push_function_type`.
private EntityId pushFunctionTypeEntity(ref Parser p, ref BlockBuilder* blocks, ref FunctionTypeT ft, InternedString ident) @trusted {
	Lookup* inputs = null;
	scope(exit) if (inputs !is null) fp.dynarray.free(inputs);
	InternedString* names = null;
	scope(exit) if (names !is null) fp.dynarray.free(names);

	foreach (i; 0 .. ft.length) {
		fp.dynarray.pushBack(inputs, ft.params[i].type);
		fp.dynarray.pushBack(names, ft.params[i].name);
	}

	auto inputSlice = inputs is null ? null : inputs[0 .. ft.length];
	auto nameSlice = names is null ? null : names[0 .. ft.length];
	return pushFunctionType(*daBack(blocks), ident, inputSlice, ft.returnType, ft.hasReturnType, nameSlice);
}

/// The C++ `function_type_t::push_function`.
private FunctionBuilder pushFunctionFromType(ref Parser p, ref BlockBuilder* blocks, ref FunctionTypeT ft, InternedString name) @trusted {
	immutable ftEntity = pushFunctionTypeEntity(p, blocks, ft, InternedString("_"));
	auto out_ = pushFunction(*daBack(blocks), name, ftEntity);

	foreach (i; 0 .. ft.length) {
		auto param = &ft.params[i];
		if (param.valueKind == ValueKind.number) {
			if (param.type.resolved())
				pushNumberParameter(out_, i, param.name, param.type.entity(), param.number);
			else
				pushNumberParameter(out_, i, param.name, param.type.name(), param.number);
		} else if (param.valueKind == ValueKind.str) {
			if (param.type.resolved())
				pushStringParameter(out_, i, param.name, param.type.entity(), param.str);
			else
				pushStringParameter(out_, i, param.name, param.type.name(), param.str);
		} else {
			if (param.type.resolved())
				pushValuelessParameter(out_, i, param.name, param.type.entity());
			else
				pushValuelessParameter(out_, i, param.name, param.type.name());
		}
	}
	return out_;
}

/// The C++ `function_type_t::push_valueless_function`.
private EntityId pushValuelessFunctionFromType(ref Parser p, ref BlockBuilder* blocks, ref FunctionTypeT ft, InternedString name) {
	return pushValuelessFunction(*daBack(blocks), name, pushFunctionTypeEntity(p, blocks, ft, InternedString("_")));
}


// ---------------------------------------------------------------------------
// Values
// ---------------------------------------------------------------------------

/// `function_call <- (<'flatten' | 'inline' | 'tail'>_)? Identifier _ '('_ (Identifier _ (','_ Identifier _)*)? ')' wsc`
private bool functionCall(ref Parser p, ref CallInfo result) @trusted {
	immutable save = p.pos;

	if (lookingAt(p, "flatten")) { advance(p, 7); skipWhitespace(p); result.flatten = true; }
	else if (lookingAt(p, "inline")) { advance(p, 6); skipWhitespace(p); result.inline_ = true; }
	else if (lookingAt(p, "tail")) { advance(p, 4); skipWhitespace(p); result.tail = true; }

	if (!identifier(p, result.function_)) { p.pos = save; return false; }
	skipWhitespace(p);
	if (peek(p) != '(') { p.pos = save; return false; }
	advance(p);
	skipWhitespace(p);

	InternedString arg;
	if (identifier(p, arg)) {
		result.inputs.push(Lookup(arg));
		skipWhitespace(p);
		for (;;) {
			immutable commaSave = p.pos;
			if (peek(p) != ',') break;
			advance(p);
			skipWhitespace(p);
			if (!identifier(p, arg)) { p.pos = commaSave; break; }
			result.inputs.push(Lookup(arg));
			skipWhitespace(p);
		}
	}

	if (peek(p) != ')') { result.free(); result = CallInfo.init; p.pos = save; return false; }
	advance(p);
	skipWsc(p);
	return true;
}

/// `Block <- block_start assignment* '}'`, with `block_start <- '{'_` pushing
/// a fresh builder onto the shared stack.
private bool block(ref Parser p, ref BlockBuilder* blocks, out EntityId result) @trusted {
	immutable save = p.pos;
	auto mod = p.mod;

	if (peek(p) != '{') return false;
	advance(p);
	skipWhitespace(p);

	// block_start's action
	immutable blockEntity = addEntity(*mod);
	addComponent!Block(*mod, blockEntity);
	fp.dynarray.pushBack(blocks, BlockBuilder(blockEntity, mod));

	while (!eof(p) && peek(p) != '}') {
		EntityId ignored;
		if (!assignment(p, blocks, ignored)) break;
	}

	if (peek(p) != '}') {
		fp.dynarray.popBack(blocks);
		p.pos = save;
		return false;
	}
	advance(p);

	result = daBack(blocks).end();
	fp.dynarray.popBack(blocks);
	return true;
}

/// `assignment_value <- Constant wsc / Block wsc / function_call / Identifier wsc / Type wsc`
private bool assignmentValue(ref Parser p, ref BlockBuilder* blocks, ref ParsedValue result) @trusted {
	auto mod = p.mod;

	if (constant(p, result)) { skipWsc(p); return true; }

	{
		EntityId blockEntity;
		if (block(p, blocks, blockEntity)) {
			result.kind = ValueKind.block;
			result.block = blockEntity;
			skipWsc(p);
			return true;
		}
	}

	{
		CallInfo call;
		if (functionCall(p, call)) {
			result.kind = ValueKind.call;
			result.call = call;
			return true;
		}
	}

	{
		InternedString ident;
		immutable save = p.pos;
		if (identifier(p, ident)) {
			skipWsc(p);
			// A bare identifier on the right-hand side is an alias call, as
			// the C++ assignment handler rewrites it.
			result.kind = ValueKind.call;
			result.call.function_ = internIn(*mod, "alias");
			result.call.inputs.push(Lookup(ident));
			return true;
		}
		p.pos = save;
	}

	{
		ParsedType t;
		if (type(p, blocks, t)) {
			skipWsc(p);
			if (t.isFunctionType) {
				result.kind = ValueKind.functionType;
				result.functionType = t.functionType;
				return true;
			}
			// A non-function Type here is unreachable: the Identifier
			// alternative above already consumed it.
			t.free();
			result.kind = ValueKind.none;
			return true;
		}
	}

	return false;
}


// ---------------------------------------------------------------------------
// change_language
// ---------------------------------------------------------------------------

/// `matching_braces <- '{' enforested_content* '}'`
private bool matchingBraces(ref Parser p) {
	immutable save = p.pos;
	if (peek(p) != '{') return false;
	advance(p);
	for (;;) {
		if (eof(p)) { p.pos = save; return false; }
		if (peek(p) == '}') { advance(p); return true; }
		if (peek(p) == '{') {
			if (!matchingBraces(p)) { p.pos = save; return false; }
			continue;
		}
		advance(p);
	}
}

/// `change_language <- 'language'_ '"' < StringChar* > '"'_ matching_braces _`
private bool changeLanguage(ref Parser p) {
	immutable save = p.pos;
	if (!literal(p, "language")) return false;
	skipWhitespace(p);
	if (peek(p) != '"') { p.pos = save; return false; }
	advance(p);
	while (stringChar(p)) {}
	if (peek(p) != '"') { p.pos = save; return false; }
	advance(p);
	skipWhitespace(p);
	if (!matchingBraces(p)) { p.pos = save; return false; }
	skipWhitespace(p);
	return true;
}


// ---------------------------------------------------------------------------
// assignment
// ---------------------------------------------------------------------------

/// `Terminator <- (';' | '\n' | '\r\n' | '\r') / !.`
private bool terminator(ref Parser p) {
	if (eof(p)) return true;
	immutable c = peek(p);
	if (c == ';') { advance(p); return true; }
	if (c == '\n') { advance(p); return true; }
	if (c == '\r') {
		advance(p);
		if (peek(p) == '\n') advance(p);
		return true;
	}
	return false;
}

/// `assignment <- change_language
///              / (<'export'>_)? Identifier _ ':'_ Type wsc (_ '='_ assignment_value)?
///                (SourceInfo wsc)? Terminator _`
private bool assignment(ref Parser p, ref BlockBuilder* blocks, out EntityId result) @trusted {
	auto mod = p.mod;
	immutable start = p.pos;
	result = invalidEntity;

	if (changeLanguage(p)) {
		// Changing languages is not supported in the prototype!
		pushDiagnostic(DiagnosticType.LanguageChangeNotSupported, spanLocation(p, start, p.pos),
			mod.source, p.path);
		return true;
	}

	bool export_ = false;
	if (lookingAt(p, "export")) {
		advance(p, 6);
		skipWhitespace(p);
		export_ = true;
	}

	InternedString ident;
	if (!identifier(p, ident)) { p.pos = start; return false; }
	skipWhitespace(p);
	if (peek(p) != ':') { p.pos = start; return false; }
	advance(p);
	skipWhitespace(p);

	ParsedType declaredType;
	if (!type(p, blocks, declaredType)) { p.pos = start; return false; }
	scope(exit) declaredType.free();
	skipWsc(p);

	ParsedValue value;
	scope(exit) value.free();
	bool hasValue = false;
	{
		immutable eqSave = p.pos;
		skipWhitespace(p);
		if (peek(p) == '=') {
			advance(p);
			skipWhitespace(p);
			if (assignmentValue(p, blocks, value)) hasValue = value.kind != ValueKind.none;
			else p.pos = eqSave;
		} else p.pos = eqSave;
	}

	Detailed location;
	bool hasLocation = false;
	{
		immutable infoSave = p.pos;
		if (sourceInfo(p, location)) {
			hasLocation = true;
			skipWsc(p);
		} else p.pos = infoSave;
	}

	if (!terminator(p)) { p.pos = start; return false; }
	skipWhitespace(p);

	result = buildAssignment(p, blocks, start, ident, declaredType, value, hasValue, location, hasLocation, export_);
	return true;
}

private EntityId buildAssignment(ref Parser p, ref BlockBuilder* blocks, size_t start, InternedString ident,
	ref ParsedType declaredType, ref ParsedValue value, bool hasValue,
	ref Detailed location, bool hasLocation, bool export_) @trusted
{
	auto mod = p.mod;
	const typeInterned = internIn(*mod, "type");
	const namespaceInterned = internIn(*mod, "namespace");
	const aliasInterned = internIn(*mod, "alias");
	const compilerInterned = internIn(*mod, "compiler");

	EntityId e = invalidEntity;

	if (!hasValue) {
		if (!declaredType.isFunctionType)
			e = pushValueless(*daBack(blocks), ident, declaredType.name);
		else
			e = pushValuelessFunctionFromType(p, blocks, declaredType.functionType, ident);

	} else final switch (value.kind) {
		case ValueKind.number:
			if (!declaredType.isFunctionType)
				e = pushNumber(*daBack(blocks), ident, declaredType.name, value.number);
			else {
				pushDiagnostic(DiagnosticType.CantStoreInFunctionRegister, spanLocation(p, start, p.pos),
					mod.source, p.path);
				return e;
			}
			break;

		case ValueKind.str:
			if (!declaredType.isFunctionType) {
				if (declaredType.name == aliasInterned)
					e = pushAlias(*daBack(blocks), ident, value.str);
				else
					e = pushString(*daBack(blocks), ident, declaredType.name, value.str);
			} else {
				pushDiagnostic(DiagnosticType.CantStoreInFunctionRegister, spanLocation(p, start, p.pos),
					mod.source, p.path);
				return e;
			}
			break;

		case ValueKind.call: {
			auto call = &value.call;
			if (!declaredType.isFunctionType) {
				if (declaredType.name == aliasInterned && call.function_ == aliasInterned)
					e = pushAlias(*daBack(blocks), ident, (*call).inputs[0].name());
				else if (call.function_ == aliasInterned) {
					auto diag = &pushDiagnostic(DiagnosticType.CantCopyRegisters,
						spanLocation(p, start, p.pos), mod.source, p.path);
					Diagnostic.Annotation annotation;
					annotation.message = text("Instead call ", DoirAnsi.func, "copy", Ansi.reset,
						" or ", DoirAnsi.func, "move", Ansi.reset);
					annotation.position = diag.location.start;
					pushAnnotation(*diag, annotation);
				} else
					e = pushCall(*daBack(blocks), ident, declaredType.name, call.function_,
						call.inputs.slice);
			} else {
				immutable ftEntity = pushFunctionTypeEntity(p, blocks, declaredType.functionType, InternedString("_"));
				e = pushCall(*daBack(blocks), ident, ftEntity, call.function_, call.inputs.slice);
			}

			if (e != invalidEntity && (call.inline_ || call.flatten || call.tail)) {
				ushort f = 0;
				if (call.inline_) f |= Flags.Inline;
				if (call.flatten) f |= Flags.Flatten;
				if (call.tail) f |= Flags.Tail;
				addComponent!Flags(*mod, e).flags = f;
			}
			break;
		}

		case ValueKind.block: {
			BlockBuilder builder;
			if (!declaredType.isFunctionType) {
				const typeName = declaredType.name;
				if (typeName == typeInterned) {
					builder = pushType(*daBack(blocks), ident);
				} else if (typeName == namespaceInterned) {
					builder = pushNamespace(*daBack(blocks), ident);
					if (ident == compilerInterned) {
						getComponent!Name(*mod, builder.block).value = internIn(*mod, "compiler_ignored");
						auto diag = &pushDiagnostic(DiagnosticType.CompilerNamespaceReserved,
							spanLocation(p, start, p.pos), mod.source, p.path);
						Diagnostic.Annotation annotation;
						annotation.message = text("Use of reserved ", DoirAnsi.type, "compiler",
							Ansi.reset, " namespace has been ignored");
						annotation.color = DoirAnsi.type;
						pushAnnotationAtStart(*diag, annotation);
						return builder.end();
					}
				} else if (typeName == aliasInterned) {
					auto diag = &pushDiagnostic(DiagnosticType.AliasNotAllowed,
						spanLocation(p, start, p.pos), mod.source, p.path);
					diag.additionalNote = text("Aliases aren't allowed to reference blocks");
					// NOTE: the C++ carries on here with a default-constructed
					// builder (null module) and dereferences it a few lines
					// later. Bailing out instead keeps the diagnostic and drops
					// the crash.
					return invalidEntity;
				} else {
					builder = pushSubblock(*daBack(blocks), ident, typeName);
					// TODO: Why does block interned keep becoming a path?
					if (typeName.view == "block")
						getOrAddComponent!Flags(*mod, builder.block).flags |= Flags.Comptime;
				}
			} else {
				builder = pushFunctionFromType(p, blocks, declaredType.functionType, ident).builder;
			}

			e = builder.block;
			auto source = BlockBuilder(value.block, mod);
			moveExisting(builder, source);
			break;
		}

		case ValueKind.functionType: {
			if (declaredType.isFunctionType) {
				auto diag = &pushDiagnostic(DiagnosticType.InvalidType, spanLocation(p, start, p.pos),
					mod.source, p.path);
				Diagnostic.Annotation annotation;
				annotation.message = text("Function types can only be assigned to registers of type ",
					DoirAnsi.type, "type", Ansi.reset);
				annotation.position = diag.location.start;
				pushAnnotation(*diag, annotation);
			} else if (declaredType.name != typeInterned) {
				auto diag = &pushDiagnostic(DiagnosticType.InvalidType, spanLocation(p, start, p.pos),
					mod.source, p.path);
				Diagnostic.Annotation annotation;
				annotation.message = text("Function types can only be assigned to registers of type ",
					DoirAnsi.type, "type", Ansi.reset);
				annotation.position = diag.location.start;
				pushAnnotation(*diag, annotation);
			}

			e = pushFunctionTypeEntity(p, blocks, value.functionType, ident);
			break;
		}

		case ValueKind.none:
			break;
	}

	if (e == invalidEntity) return e;

	if (hasLocation)
		addComponent!Detailed(*mod, e) = location;
	else if (p.guaranteeSourceLocation
		&& !(hasComponent!SourceLocation(*mod, e) || hasComponent!Detailed(*mod, e)))
		getOrAddComponent!SourceLocation(*mod, e) = spanLocation(p, start, p.pos);

	if (export_)
		getOrAddComponent!Flags(*mod, e).flags = Flags.Export;

	return e;
}


// ---------------------------------------------------------------------------
// Entry points
// ---------------------------------------------------------------------------

private void reportSyntaxError(ref Parser p) @trusted {
	auto mod = p.mod;
	diagnostics().registerSource(p.path, p.source);

	auto location = SourceLocation(p.path, p.furthest,
		p.furthest < p.source.length ? p.furthest + 1 : p.furthest);

	Diagnostic diag;
	diag.kind = Kind.error;
	diag.message = text("Syntax error");
	diag.location = location.toDetailed(p.source);
	diagnostics().push(diag);
}

/// `program <- _ assignment* !.` - parses `source` into the block on top of
/// `blocks`.
bool parseSource(ref Module mod, ref BlockBuilder* blocks, const(char)[] source,
	const(char)[] path = "generated.doir", bool guaranteeSourceLocation = true) @trusted
{
	const backupWorkingFile = mod.workingFile;
	immutable backupHasWorkingFile = mod.hasWorkingFile;
	const backupSource = mod.source;

	mod.workingFile = path;
	mod.hasWorkingFile = true;
	mod.source = source;

	Parser p;
	p.mod = &mod;
	p.source = source;
	p.path = path;
	p.guaranteeSourceLocation = guaranteeSourceLocation;

	skipWhitespace(p);
	while (!eof(p)) {
		EntityId ignored;
		if (!assignment(p, blocks, ignored)) break;
	}

	immutable ok = eof(p);
	if (!ok) reportSyntaxError(p);

	mod.workingFile = backupWorkingFile;
	mod.hasWorkingFile = backupHasWorkingFile;
	// NOTE: `mod.source` is deliberately *not* restored, matching the C++
	// `module::parse`, which only restores `working_file`. Diagnostics raised
	// after a parse point into the file just parsed.
	cast(void) backupSource;

	return ok;
}

/// Loads `path` and parses it.
bool parseFile(ref Module mod, ref BlockBuilder* blocks, const(char)[] path,
	bool guaranteeSourceLocation = true) @trusted
{
	bool ok;
	auto source = getFileString(path, ok);
	if (!ok) return false;
	diagnostics().registerSource(path, source);
	return parseSource(mod, blocks, source, path, guaranteeSourceLocation);
}


// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
// Ported from tests/parse.test.cpp, plus the seven core assignment forms of
// tests/spec_syntax.test.cpp.

version (unittest) {
	import doir.verify : structure;
	import tests.pipeline_helper;
}

unittest { // a minimal single assignment parses and passes verify.structure
	diagnostics().clear();
	auto mod = createModule();
	scope(exit) free(mod);

	BlockBuilder* builders;
	scope(exit) fp.dynarray.free(builders);
	auto builtin = createBlockBuilder(mod);
	buildBuiltinBlock(builtin);
	fp.dynarray.pushBack(builders, builtin);

	assert(parseSource(mod, builders, "x : compiler.byte = 5\n", "minimal.doir"));
	assert(!diagnostics().hasErrors());

	auto root = builders[0].block;
	assert(structure(diagnostics(), mod, root));
	assert(!diagnostics().hasErrors());
	diagnostics().clear();
}

unittest { // a syntactically invalid source produces a parse failure, not a crash
	diagnostics().clear();
	auto mod = createModule();
	scope(exit) free(mod);

	BlockBuilder* builders;
	scope(exit) fp.dynarray.free(builders);
	auto builtin = createBlockBuilder(mod);
	buildBuiltinBlock(builtin);
	fp.dynarray.pushBack(builders, builtin);

	assert(!parseSource(mod, builders, "this is not : : valid doir syntax !!!\n", "invalid.doir"));
	diagnostics().clear();
}


// --- doir.spec syntax -------------------------------------------------------
//
// The seven core assignment forms doir.spec (lines 1-14) lists as the
// language's basic building blocks, using real source text driven through the
// exact pipeline the driver uses. `language "..." { ... }` blocks (the
// asterisked eighth form) are intentionally not covered: changing languages is
// explicitly rejected by the parser - there is no implementation to test.
//
// Every entity is looked up *by name* after the pipeline runs rather than by
// the id it was created with, because `canonicalize.sort` renumbers entities
// partway through - names travel with an entity across that renumbering, ids
// don't.

unittest { // #1 constant assignment: name : type = value
	auto r = compile("%1 : compiler.byte = 5\n");
	scope(exit) free(r.mod);
	assert(r.ok);

	immutable e = find(r.mod, r.root, "%1");
	assert(e != invalidEntity);
	assert(hasComponent!Number(r.mod, e));
	assert(getComponent!Number(r.mod, e).value == 5);
}

unittest { // #2 block assignment: name : block = { ... }
	// `export`ed so `opt.stripFreestandingBlocks` (correctly) doesn't remove it:
	// an un-exported, never-referenced block is genuinely dead code once the
	// block itself isn't consumed by anything.
	auto r = compile("export blk : block = {\n\t%1 : compiler.byte = 6\n}\n");
	scope(exit) free(r.mod);
	assert(r.ok);

	immutable blk = find(r.mod, r.root, "blk");
	assert(blk != invalidEntity);
	assert(hasComponent!Block(r.mod, blk));
	assert(daLength(getComponent!Block(r.mod, blk).related) == 1);
}

unittest { // #3 function execution: _ : type = function(args...)
	auto r = compile("%0 : compiler.byte = 0x41\n%1 : compiler.byte = compiler.emit(%0)\n");
	scope(exit) free(r.mod);
	assert(r.ok);
	static immutable ubyte[1] expected = [0x41];
	assert(emits(r, expected[]));
}

unittest { // #4 alias assignment: name : alias = target
	auto r = compile("%1 : compiler.byte = 5\n%2 : alias = %1\n");
	scope(exit) free(r.mod);
	assert(r.ok);

	immutable target = find(r.mod, r.root, "%1");
	immutable aliasE = find(r.mod, r.root, "%2");
	assert(aliasE != invalidEntity);
	assert(hasComponent!Alias(r.mod, aliasE));
	assert(getComponent!Alias(r.mod, aliasE).related[0] == target);
}

unittest { // #5 namespace assignment, with dotted member access
	auto r = compile("math : namespace = {\n\tval : compiler.byte = 7\n}\n");
	scope(exit) free(r.mod);
	assert(r.ok);

	immutable math = find(r.mod, r.root, "math");
	assert(math != invalidEntity);
	assert(flagsSet(r.mod, math, Flags.Namespace));

	immutable val = find(r.mod, r.root, "math.val");
	assert(val != invalidEntity);
	assert(hasComponent!Number(r.mod, val));
	assert(getComponent!Number(r.mod, val).value == 7);
}

unittest { // #6 type assignment: name : type = { field declarations... }
	auto r = compile("vec2 : type = {\n\tx : compiler.byte\n\ty : compiler.byte\n}\n");
	scope(exit) free(r.mod);
	assert(r.ok);

	immutable vec2 = find(r.mod, r.root, "vec2");
	assert(vec2 != invalidEntity);
	assert(hasComponent!TypeDefinition(r.mod, vec2));
	assert(hasComponent!Block(r.mod, vec2));
	assert(daLength(getComponent!Block(r.mod, vec2).related) == 2);
}

unittest { // #7 undefined assignment: name : type (no value)
	auto r = compile("x : compiler.byte\n");
	scope(exit) free(r.mod);
	assert(r.ok);

	immutable x = find(r.mod, r.root, "x");
	assert(x != invalidEntity);
	assert(flagsSet(r.mod, x, Flags.Valueless));
	assert(!hasComponent!Number(r.mod, x));
	assert(!hasComponent!DString(r.mod, x));
	assert(!hasComponent!Call(r.mod, x));
}
