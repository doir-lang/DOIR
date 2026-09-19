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
}

void free(ref CallInfo c) { doir.interface_.free(c.inputs); }

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
	// The span the rule consumed. An anonymous function-type entity is not
	// named and is not the entity the enclosing assignment attaches its own
	// location to, so this is the only location it can ever be given - and it
	// carries the lookups a failed parameter type reports against.
	size_t start = 0, end = 0;
}

void free(ref FunctionTypeT t) @trusted {
	if (t.params !is null) { fp.dynarray.free(t.params); t.params = null; }
}

size_t length(ref const FunctionTypeT t) @trusted {
	return daLength(cast(FunctionTypeParam*) t.params);
}

/// Either a resolved-by-name type (`lookup::type_of`) or a function type.
struct ParsedType {
	bool isFunctionType = false;
	InternedString name;     // when !isFunctionType
	FunctionTypeT functionType;
}

void free(ref ParsedType t) { free(t.functionType); }

/// The right-hand side of an assignment.
struct ParsedValue {
	ValueKind kind = ValueKind.none;
	real number = 0;
	InternedString str;
	CallInfo call;
	EntityId block;
	FunctionTypeT functionType;
}

void free(ref ParsedValue v) { free(v.call); free(v.functionType); }


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
	size_t depth;    // open nesting levels, for the recursion guard below
	bool depthExceeded; // sticky: some rule bottomed out on `maxNestingDepth`
}

/// How deep `{`, `(a: T) -> U` and a `language` block's braces may nest.
///
/// The rules below are recursive descent, so nesting is stack depth: a block
/// costs an `assignment`/`assignmentValue`/`block` trio, a function type a
/// `type`/`functionType`/`parameter`/`deducibleType` one, a few hundred bytes
/// a level either way. Source nested about ten thousand deep overflowed the
/// stack outright, so the cap turns that into a diagnostic - well above
/// anything real (the deepest `.doir` in the repo nests three) and well below
/// what a default stack holds.
private enum maxNestingDepth = 512;

/// Claims a nesting level, or fails the rule when there are none left. Every
/// caller pairs this with `scope(exit) --p.depth;`.
private bool enterNesting(ref Parser p) {
	if (p.depth >= maxNestingDepth) {
		p.depthExceeded = true;
		return false;
	}
	++p.depth;
	return true;
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

/// `HexExponent <- [pP][+\-]? [0-9]*` / `DecExponent <- 'e'i[+\-]? [0-9]*`.
///
/// The digits are optional, so a marker with nothing behind it is consumed as
/// part of the number rather than left for `Terminator`. Returns whether a
/// marker was there at all - which is one of the two things that make a token
/// a float rather than an integer.
private bool exponentPart(ref Parser p, char lower, char upper) {
	if (peek(p) != lower && peek(p) != upper) return false;
	advance(p);
	if (peek(p) == '+' || peek(p) == '-') advance(p);
	while (!eof(p) && isDigit(peek(p))) advance(p);
	return true;
}

/// `FloatConstant <- ('0x' (HexDigit* '.' HexDigit+ / HexDigit+ '.' HexDigit*) HexExponent?
///                 / '0x' HexDigit+ HexExponent)
///                 / (([0-9]* '.' [0-9]+ / [0-9]+ '.' [0-9]*) DecExponent?
///                 / [0-9]+ DecExponent)`
///
/// A float is exactly a number token carrying a `.` or an exponent marker;
/// anything else is an `IntegerConstant`. Both halves below are the same shape:
/// read the digits, then the optional point and its digits, then the optional
/// exponent, and fail unless one of the last two was there.
private bool floatConstant(ref Parser p) {
	immutable save = p.pos;

	if (lookingAt(p, "0x") || lookingAt(p, "0X")) {
		advance(p, 2);

		immutable mantissaStart = p.pos;
		while (!eof(p) && isHexDigit(peek(p))) advance(p);
		immutable hasLeadingDigits = p.pos > mantissaStart;

		bool hasPoint = false;
		if (peek(p) == '.') {
			immutable pointAt = p.pos;
			advance(p);
			while (!eof(p) && isHexDigit(peek(p))) advance(p);
			// `HexDigit* '.' HexDigit+` or `HexDigit+ '.' HexDigit*`: a point
			// with no digit on either side of it is neither.
			if (!hasLeadingDigits && p.pos == pointAt + 1) { p.pos = save; return false; }
			hasPoint = true;
		} else if (!hasLeadingDigits) {
			p.pos = save;
			return false;
		}

		if (!exponentPart(p, 'p', 'P') && !hasPoint) { p.pos = save; return false; }
		return true;
	}

	immutable mantissaStart = p.pos;
	while (!eof(p) && isDigit(peek(p))) advance(p);
	immutable hasLeadingDigits = p.pos > mantissaStart;

	bool hasPoint = false;
	if (peek(p) == '.') {
		immutable pointAt = p.pos;
		advance(p);
		while (!eof(p) && isDigit(peek(p))) advance(p);
		if (!hasLeadingDigits && p.pos == pointAt + 1) { p.pos = save; return false; }
		hasPoint = true;
	} else if (!hasLeadingDigits) {
		p.pos = save;
		return false;
	}

	if (!exponentPart(p, 'e', 'E') && !hasPoint) { p.pos = save; return false; }
	return true;
}

/// Matches `text_` only when it stands as a whole keyword token - that is,
/// when the character behind it cannot continue an identifier.
///
/// The grammar spells every keyword as bare text followed by `_`, and `_`
/// matches the empty string, so `'export'` also matches the front of
/// `exported`. That is a silent misparse rather than a rejection:
/// `exported : compiler.byte = 1` consumed `export` as the modifier and
/// declared something called `ed`. It also made `inlined`, `flattened`,
/// `tailcall` and friends unusable as names. A keyword is a token, so it is
/// matched as one here (and `grammar.peg` says so now too).
private bool lookingAtKeyword(ref Parser p, const(char)[] text_) @trusted {
	if (!lookingAt(p, text_)) return false;

	immutable at = p.pos + text_.length;
	if (at >= p.source.length) return true;
	if (p.source[at] == '.') return false; // a dotted path continues the name

	size_t width;
	return !identifierContinueAt(p, at, width);
}

/// `Keywords <- ('deduced' | 'export' | 'flatten' | 'inline' | 'language' | 'tail') !UnicodeIdentifierContinue`
private bool atKeyword(ref Parser p) {
	static immutable string[6] keywords = ["deduced", "export", "flatten", "inline", "language", "tail"];
	foreach (k; keywords)
		if (lookingAtKeyword(p, k)) return true;
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
/// float, integer, string, char. `FloatConstant` only matches a token carrying
/// a `.` or an exponent, so every other number - `1234`, `0x1F`, `0b1011`,
/// `0755` - falls through to `IntegerConstant` and its own four bases.
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
/// `std::stoi(token, nullptr, 0)` which is what actually decodes `0x...`.
private real tokenToNumber(const(char)[] token) @trusted {
	import core.stdc.stdlib : strtol, strtold, strtoull;

	import core.stdc.string : memcpy;
	char[64] buffer;
	immutable n = token.length < buffer.length - 1 ? token.length : buffer.length - 1;
	if (n) memcpy(buffer.ptr, token.ptr, n);
	buffer[n] = '\0';

	// Binary is decoded here rather than left to the two C functions below:
	// neither knows `0b`, and both stop at the `b` and report 0. (The C++ has
	// the same hole, but the grammar there never reached `'0b' [01]*` at all,
	// so a binary literal could not be written in the first place.)
	if (n > 2 && buffer[0] == '0' && (buffer[1] == 'b' || buffer[1] == 'B'))
		return cast(real) strtoull(buffer.ptr + 2, null, 2);

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
		auto contents = getFileString(result.file);
		if (!contents.isNull) {
			result.start.column = 1;
			result.end.column = lineLength(contents.get, result.start.line - 1) + 1;
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
	if (lookingAtKeyword(p, "deduced")) {
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
	if (!enterNesting(p)) return false;
	scope(exit) --p.depth;
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
	result.start = save;
	result.end = p.pos;
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
	immutable out_ = pushFunctionType(*daBack(blocks), ident, inputSlice, ft.returnType, ft.hasReturnType, nameSlice);

	// An anonymous function type gets no `Name` out of `pushCommon` and is not
	// the entity `buildAssignment` hangs its span on, so without this it has no
	// location at all - and `lookupsResolved`, reporting an unresolved
	// parameter or return type against it, panicked in `findSourceLocation`
	// rather than printing the error.
	if (ident.view == "_" && p.guaranteeSourceLocation && ft.end > ft.start)
		getOrAddComponent!SourceLocation(*p.mod, out_) = spanLocation(p, ft.start, ft.end);

	return out_;
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

	if (lookingAtKeyword(p, "flatten")) {
		advance(p, "flatten".length); skipWhitespace(p); result.flatten = true;
	} else if (lookingAtKeyword(p, "inline")) {
		advance(p, "inline".length); skipWhitespace(p); result.inline_ = true;
	} else if (lookingAtKeyword(p, "tail")) {
		advance(p, "tail".length); skipWhitespace(p); result.tail = true;
	}

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
	if (!enterNesting(p)) return false;
	scope(exit) --p.depth;
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

	result = end(*daBack(blocks));
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
		// `Type` is `FunctionType / Identifier`, and only the first half can
		// match here: the `Identifier` alternative above already consumed
		// anything the second would have. So this goes straight to
		// `functionType` rather than through `type`.
		FunctionTypeT ft;
		if (functionType(p, blocks, ft)) {
			skipWsc(p);
			result.kind = ValueKind.functionType;
			result.functionType = ft;
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
	if (!enterNesting(p)) return false;
	scope(exit) --p.depth;
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
	if (!lookingAtKeyword(p, "language")) return false;
	advance(p, "language".length);
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
	if (lookingAtKeyword(p, "export")) {
		advance(p, "export".length);
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
				if (declaredType.name == aliasInterned && call.function_ == aliasInterned) {
					// `alias` names exactly one thing. Without this check
					// `x : alias = alias()` indexed an empty argument list and
					// dereferenced null.
					if (doir.interface_.length((*call).inputs) != 1) {
						auto diag = &pushDiagnostic(DiagnosticType.InvalidFunctionCall,
							spanLocation(p, start, p.pos), mod.source, p.path);
						Diagnostic.Annotation annotation;
						annotation.message = text(DoirAnsi.func, "alias", Ansi.reset,
							" takes exactly one argument, but was given ",
							doir.interface_.length((*call).inputs));
						annotation.position = diag.location.start;
						pushAnnotation(*diag, annotation);
						return invalidEntity;
					}
					e = pushAlias(*daBack(blocks), ident, (*call).inputs[0].name());
				} else if (call.function_ == aliasInterned) {
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

	// OR rather than assign: the value handled above may already have set
	// flags on `e` (Inline/Flatten/Tail from a call, Comptime from a `block`,
	// Namespace from `pushNamespace`), and clobbering those produced IR that
	// `doir.verify` rejects outright - `export x : namespace = { }` lost its
	// Namespace bit and panicked with "Invalid flags".
	if (export_)
		getOrAddComponent!Flags(*mod, e).flags |= Flags.Export;

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
	// A rule that ran out of nesting levels fails like any other, so the parse
	// stops with the cursor at the deepest `{` or `(` - saying "syntax error"
	// there would point at source that is perfectly well formed.
	diag.message = p.depthExceeded
		? text("Nesting too deep (the limit is ", maxNestingDepth, " levels)")
		: text("Syntax error");
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
	registerSource(mod, path, source);

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
	// after a parse point into the file just parsed - which is why a location
	// that names a file is resolved against `sourceOf(mod, file)` rather than
	// against `mod.source`.
	cast(void) backupSource;

	return ok;
}

/// Loads `path` and parses it.
///
/// A file that cannot be opened raises `FileDoesNotExist` rather than only
/// returning false: every caller reports through `diagnostics()` and treats an
/// empty diagnostic set as success, so a silent false made the driver compile
/// an empty module and exit 0 for a path that does not exist.
bool parseFile(ref Module mod, ref BlockBuilder* blocks, const(char)[] path,
	bool guaranteeSourceLocation = true) @trusted
{
	auto source = getFileString(path);
	if (source.isNull) {
		auto diag = &pushDiagnostic(DiagnosticType.FileDoesNotExist,
			SourceLocation(path, 0, 0), "", path);
		Diagnostic.Annotation annotation;
		annotation.message = text("Could not open ", DoirAnsi.file, "`", path, "`", Ansi.reset);
		annotation.color = DoirAnsi.file;
		annotation.position = diag.location.start;
		pushAnnotation(*diag, annotation);
		return false;
	}
	diagnostics().registerSource(path, source.get);
	return parseSource(mod, blocks, source.get, path, guaranteeSourceLocation);
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
	scope(exit) freeModule(mod);

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

unittest {
	// Every file parsed into a module leaves `mod.source` pointing at itself,
	// so after an `early_include` it names the *included* file while the
	// entities around the call still carry offsets into the includer. Those
	// have to keep resolving against the includer's text: against the wrong
	// file they report the wrong lines, and - once the included file is the
	// shorter of the two - walk off the end of it, which aborted the compiler
	// inside `SourceLocation.findPair`.
	diagnostics().clear();
	auto mod = createModule();
	scope(exit) freeModule(mod);

	BlockBuilder* builders;
	scope(exit) fp.dynarray.free(builders);
	auto builtin = createBlockBuilder(mod);
	buildBuiltinBlock(builtin);
	fp.dynarray.pushBack(builders, builtin);

	assert(parseSource(mod, builders,
		"outerA : compiler.byte = 1\nouterB : compiler.byte = 2\n", "outer.doir"));
	// Shorter than the text above, the way an included file usually is.
	assert(parseSource(mod, builders, "inner : compiler.byte = 3\n", "inner.doir"));
	assert(!diagnostics().hasErrors());

	immutable root = builders[0].block;
	auto outer = findDetailedSourceLocation(mod, find(mod, root, "outerB"));
	assert(outer.file == "outer.doir");
	assert(outer.start.line == 2);

	auto inner = findDetailedSourceLocation(mod, find(mod, root, "inner"));
	assert(inner.file == "inner.doir");
	assert(inner.start.line == 1);
	diagnostics().clear();
}

unittest { // a syntactically invalid source produces a parse failure, not a crash
	diagnostics().clear();
	auto mod = createModule();
	scope(exit) freeModule(mod);

	BlockBuilder* builders;
	scope(exit) fp.dynarray.free(builders);
	auto builtin = createBlockBuilder(mod);
	buildBuiltinBlock(builtin);
	fp.dynarray.pushBack(builders, builtin);

	assert(!parseSource(mod, builders, "this is not : : valid doir syntax !!!\n", "invalid.doir"));
	diagnostics().clear();
}

unittest {
	// An anonymous function type is pushed as its own entity named `_`, which
	// `pushCommon` gives no `Name` and which no assignment hangs a span on. It
	// is also what carries the parameter and return-type lookups, so reporting
	// an unresolvable one against it sent `findSourceLocation` looking for a
	// location that did not exist - and it panicked rather than printing the
	// error. Each of these reaches that entity by a different route.
	static foreach (source; [
		"f : (x: nope) -> nope\n",              // valueless function
		"f : (x: nope = 3) -> nope\n",          // ...with a default parameter
		"f : (x: (y: nope) -> nope) -> u64\n",  // function type *as* a parameter
	]) {{
		auto r = compile(source);
		scope(exit) freeModule(r.mod);
		assert(!r.ok);
		assert(diagnostics().hasErrors());
	}}
	diagnostics().clear();
}

unittest {
	// Nesting is stack depth in a recursive-descent parser, so source nested
	// deeply enough used to overflow the stack instead of failing. Each of the
	// three recursive rules is capped; what matters is that all three come
	// back rather than dying, whatever the diagnostic ends up saying.
	enum levels = maxNestingDepth + 16;

	static bool rejects(const(char)[] open, const(char)[] close) {
		char[levels * 16] buffer = void;
		size_t n = 0;
		foreach (_; 0 .. levels) { buffer[n .. n + open.length] = open[]; n += open.length; }
		foreach (_; 0 .. levels) { buffer[n .. n + close.length] = close[]; n += close.length; }

		auto r = compile(buffer[0 .. n]);
		scope(exit) freeModule(r.mod);
		return !r.ok && diagnostics().hasErrors();
	}

	assert(rejects("b : block = {\n", "}\n"));  // block
	assert(rejects("(x: ", ") -> u64"));        // functionType
	diagnostics().clear();

	// `language`'s braces recurse through `matchingBraces`, which has no
	// per-level suffix to pair off, so it is spelled out rather than shaped to
	// the helper above.
	{
		char[levels * 2 + 32] buffer = void;
		size_t n = 0;
		buffer[n .. n + 13] = `language "x" `; n += 13;
		foreach (_; 0 .. levels) buffer[n++] = '{';
		foreach (_; 0 .. levels) buffer[n++] = '}';
		buffer[n++] = '\n';

		auto r = compile(buffer[0 .. n]);
		scope(exit) freeModule(r.mod);
		assert(!r.ok);
		assert(diagnostics().hasErrors());
	}
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
	scope(exit) freeModule(r.mod);
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
	scope(exit) freeModule(r.mod);
	assert(r.ok);

	immutable blk = find(r.mod, r.root, "blk");
	assert(blk != invalidEntity);
	assert(hasComponent!Block(r.mod, blk));
	assert(daLength(getComponent!Block(r.mod, blk).related) == 1);
}

unittest { // #3 function execution: _ : type = function(args...)
	auto r = compile("%0 : compiler.byte = 0x41\n%1 : compiler.byte = compiler.emit(%0)\n");
	scope(exit) freeModule(r.mod);
	assert(r.ok);
	static immutable ubyte[1] expected = [0x41];
	assert(emits(r, expected[]));
}

unittest { // #4 alias assignment: name : alias = target
	auto r = compile("%1 : compiler.byte = 5\n%2 : alias = %1\n");
	scope(exit) freeModule(r.mod);
	assert(r.ok);

	immutable target = find(r.mod, r.root, "%1");
	immutable aliasE = find(r.mod, r.root, "%2");
	assert(aliasE != invalidEntity);
	assert(hasComponent!Alias(r.mod, aliasE));
	assert(getComponent!Alias(r.mod, aliasE).related[0] == target);
}

unittest {
	// `export` must OR its bit in rather than replace whatever the value
	// already set. `pushNamespace` marks the entity `Namespace`; assigning
	// `Flags.Export` over that left IR `doir.verify` rejects, so this source
	// used to abort the compiler with "Invalid flags".
	auto r = compile("export ns : namespace = {\n\tval : compiler.byte = 7\n}\n");
	scope(exit) freeModule(r.mod);
	assert(r.ok);

	immutable ns = find(r.mod, r.root, "ns");
	assert(ns != invalidEntity);
	assert(flagsSet(r.mod, ns, Flags.Namespace));
	assert(flagsSet(r.mod, ns, Flags.Export));
}

unittest { // ditto for the Comptime bit a `block`-typed assignment sets
	auto r = compile("export blk : block = {\n\t%1 : compiler.byte = 6\n}\n");
	scope(exit) freeModule(r.mod);
	assert(r.ok);

	immutable blk = find(r.mod, r.root, "blk");
	assert(blk != invalidEntity);
	assert(flagsSet(r.mod, blk, Flags.Export));
	assert(flagsSet(r.mod, blk, Flags.Comptime));
}

unittest {
	// `alias` names exactly one thing. A zero-argument `alias()` used to index
	// an empty argument list and segfault on the null dynarray; it has to be a
	// diagnostic instead.
	auto r = compile("x : alias = alias()\n");
	scope(exit) freeModule(r.mod);
	assert(!r.ok);
	assert(diagnostics().hasErrors());
	diagnostics().clear();
}

unittest { // ...and so does a two-argument one
	auto r = compile("%1 : compiler.byte = 5\nx : alias = alias(%1, %1)\n");
	scope(exit) freeModule(r.mod);
	assert(!r.ok);
	assert(diagnostics().hasErrors());
	diagnostics().clear();
}

unittest {
	// A file that cannot be opened has to raise `FileDoesNotExist`, not just
	// return false: the driver reports through `diagnostics()` and treats an
	// empty diagnostic set as success, so a silent false made it compile an
	// empty module and exit 0.
	diagnostics().clear();
	auto mod = createModule();
	scope(exit) freeModule(mod);

	BlockBuilder* builders;
	scope(exit) fp.dynarray.free(builders);
	auto builtin = createBlockBuilder(mod);
	buildBuiltinBlock(builtin);
	fp.dynarray.pushBack(builders, builtin);

	assert(!parseFile(mod, builders, "/nonexistent/does_not_exist.doir"));
	assert(diagnostics().hasErrors());
	diagnostics().clear();
}

unittest {
	// A keyword only counts when it stands as a whole token. The grammar spelled
	// each one as bare text followed by `_`, which matches the empty string, so
	// `export` also matched the front of `exported` - and this source silently
	// declared something named `ed` with the export flag set rather than a
	// register named `exported`.
	auto r = compile("exported : compiler.byte = 1\n");
	scope(exit) freeModule(r.mod);
	assert(r.ok);
	assert(find(r.mod, r.root, "exported") != invalidEntity);
	assert(find(r.mod, r.root, "ed") == invalidEntity);
	assert(!flagsSet(r.mod, find(r.mod, r.root, "exported"), Flags.Export));
}

unittest { // ...and the other five are usable as names again, not syntax errors
	static immutable string[5] names = ["inlined", "flattened", "tailcall", "deducedX", "language2"];
	foreach (name; names) {
		auto source = text(name, " : compiler.byte = 1\n");
		scope(exit) strFree(source);

		auto r = compile(strSlice(source));
		scope(exit) freeModule(r.mod);
		assert(r.ok);
		assert(find(r.mod, r.root, name) != invalidEntity);
	}
}

unittest { // a real `export` keyword is still recognised
	auto r = compile("export y : compiler.byte = 2\n");
	scope(exit) freeModule(r.mod);
	assert(r.ok);
	assert(flagsSet(r.mod, find(r.mod, r.root, "y"), Flags.Export));
}

unittest { // #5 namespace assignment, with dotted member access
	auto r = compile("math : namespace = {\n\tval : compiler.byte = 7\n}\n");
	scope(exit) freeModule(r.mod);
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
	scope(exit) freeModule(r.mod);
	assert(r.ok);

	immutable vec2 = find(r.mod, r.root, "vec2");
	assert(vec2 != invalidEntity);
	assert(hasComponent!TypeDefinition(r.mod, vec2));
	assert(hasComponent!Block(r.mod, vec2));
	assert(daLength(getComponent!Block(r.mod, vec2).related) == 2);
}

unittest { // #7 undefined assignment: name : type (no value)
	auto r = compile("x : compiler.byte\n");
	scope(exit) freeModule(r.mod);
	assert(r.ok);

	immutable x = find(r.mod, r.root, "x");
	assert(x != invalidEntity);
	assert(flagsSet(r.mod, x, Flags.Valueless));
	assert(!hasComponent!Number(r.mod, x));
	assert(!hasComponent!DString(r.mod, x));
	assert(!hasComponent!Call(r.mod, x));
}


// --- Lexical forms ----------------------------------------------------------
//
// The rules above are a hand transcription of grammar.peg, and most of what
// they accept never appears in the `.doir` files the pipeline tests compile:
// comments, the four integer bases, floats, character literals, quoted
// identifiers, every string escape, `<file:line:col>` source info. These
// drive each of those through `parseSource` - parse only, since a lexical
// form is the parser's business and several of them name types no pipeline
// would resolve.

version (unittest) {
	/// A module with its builtin block open as `builders[0]`, the way
	/// `parseSource`'s callers set one up.
	private struct ParseFixture {
		Module mod;
		BlockBuilder* builders;
		EntityId root;
	}

	private ParseFixture makeParseFixture() @trusted {
		ParseFixture f;
		f.mod = createModule();
		auto builtin = createBlockBuilder(f.mod);
		buildBuiltinBlock(builtin);
		fp.dynarray.pushBack(f.builders, builtin);
		f.root = f.builders[0].block;
		return f;
	}

	private void free(ref ParseFixture f) @trusted {
		fp.dynarray.free(f.builders);
		freeModule(f.mod);
	}

	/// Parses `source` into a throwaway module and reports whether it parsed.
	/// `errors` comes back set if anything was diagnosed along the way.
	private bool parses(const(char)[] source, out bool errors) {
		diagnostics().clear();
		auto f = makeParseFixture();
		scope(exit) f.free();
		immutable ok = parseSource(f.mod, f.builders, source, "lexical.doir");
		errors = diagnostics().hasErrors();
		diagnostics().clear();
		return ok;
	}

	/// Ditto, ignoring the diagnostics.
	private bool parses(const(char)[] source) {
		bool ignored;
		return parses(source, ignored);
	}

	/// Parses `x : compiler.byte = <literal>` and hands back what the literal
	/// decoded to.
	private real parsedNumber(const(char)[] literal) {
		import doir.diagnostics : text;

		diagnostics().clear();
		auto f = makeParseFixture();
		scope(exit) f.free();

		auto source = text("x : compiler.byte = ", literal, "\n");
		scope(exit) strFree(source);

		assert(parseSource(f.mod, f.builders, strSlice(source), "number.doir"));
		assert(!diagnostics().hasErrors());
		immutable x = resolveLookupName(f.mod, internIn(f.mod, "x"), f.root);
		assert(x != invalidEntity);
		scope(exit) diagnostics().clear();
		return getComponent!Number(f.mod, x).value;
	}
}

unittest { // all three comment forms, in leading and trailing position
	assert(parses("// line comment\nx : compiler.byte = 1\n"));
	assert(parses("# hash comment\nx : compiler.byte = 1\n"));
	assert(parses("/* block\n   comment */\nx : compiler.byte = 1\n"));
	assert(parses("x : compiler.byte = 1 // trailing\n"));
	assert(parses("x : /* inline */ compiler.byte = 1\n"));
	// An unterminated block comment runs to end of input rather than failing.
	assert(parses("x : compiler.byte = 1\n/* unterminated"));
}

unittest { // the Unicode spaces the `_` rule lists are whitespace too
	// U+00A0 no-break space, U+2003 em space, U+3000 ideographic space.
	assert(parses("x\u00a0:\u2003compiler.byte\u3000=\u00a01\n"));
	// ...and a non-space non-ASCII codepoint is an identifier character.
	assert(parses("\u00e9 : compiler.byte = 1\n"));
}

unittest { // integer constants, in all four of the grammar's bases
	assert(parsedNumber("0x1F") == 31);    // hex
	assert(parsedNumber("0b1011") == 11);  // binary
	assert(parsedNumber("0755") == 755);   // leading zero
	assert(parsedNumber("91") == 91);      // decimal

	// A `FloatConstant` is exactly a number carrying a `.` or an exponent, so
	// none of the above is one - which is what lets each reach its own
	// `IntegerConstant` alternative. `0b1011` in particular used to match the
	// float `0` and leave `b1011` behind, failing the whole assignment.
	assert(parsedNumber("0b0") == 0);
	assert(parsedNumber("0b") == 0);       // `'0b' [01]*` allows no digits
	assert(parsedNumber("0") == 0);
}

unittest {
	// `tokenToNumber` reads the token the rule matched, so the base has to be
	// recovered from the text: `strtold` handles decimal and `0x`, `strtol`
	// base 0 the leading-zero form, and binary is decoded by hand because
	// neither of them knows `0b` (both stop at the `b` and report 0).
	assert(parsedNumber("0b11111111") == 255);
	assert(parsedNumber("0B1010") == 10);
	assert(parsedNumber("0x48") == 0x48);
}

unittest {
	// `SourceInfo` reads its line and column numbers with the same
	// `IntegerConstant` rule, but converts them with `tokenToSize`, which is
	// base 10 flat - so `0x10` there is 0 and gets diagnosed for it. The rule
	// still matches, which is what is under test.
	bool errors;
	assert(parses("x : compiler.byte = 1 <a.doir:0x10:3>\n", errors));
	assert(errors);
	assert(parses("x : compiler.byte = 1 <a.doir:0b11:3>\n", errors));
	assert(errors);
	// A leading-zero column is read as octal by the rule and as decimal by
	// `tokenToSize`; nothing validates how far into the line it points, so
	// this one is accepted without complaint.
	assert(parses("x : compiler.byte = 1 <a.doir:1:0755>\n", errors));
	// `0x` with no hex digit behind it is not an integer, so this is not a
	// source-info suffix at all and the assignment fails on the leftovers.
	assert(!parses("x : compiler.byte = 1 <a.doir:0x:3>\n", errors));
}

unittest { // float constants, decimal and hexadecimal
	// A point with digits on either side, on one side, or on the other.
	assert(parsedNumber("1.5") == 1.5);
	assert(parsedNumber(".5") == 0.5);
	assert(parsedNumber("1.") == 1);
	assert(parsedNumber("0x1.8") == 1.5);
	assert(parsedNumber("0x.8") == 0.5);
	assert(parsedNumber("0xFF.") == 255);

	// An exponent, with and without a point in front of it.
	assert(parsedNumber("1e10") == 1e10);
	assert(parsedNumber("1.5E+3") == 1500);
	assert(parsedNumber("1.5e-3") == 1.5e-3);
	assert(parsedNumber("0x1.8p3") == 12);
	assert(parsedNumber("0x1p3") == 8);
}

unittest { // a point with no digit on either side of it is not a number
	bool errors;
	assert(!parses("x : compiler.byte = .\n", errors));
	assert(!parses("x : compiler.byte = 0x.\n", errors));
}

unittest {
	// An exponent marker with no digits behind it is still consumed as part of
	// the number - `DecExponent` and `HexExponent` end in `[0-9]*`, not
	// `[0-9]+` - and contributes nothing to the value. Left behind instead it
	// would not be a `Terminator`, and the assignment around it would fail.
	assert(parsedNumber("1e") == 1);
	assert(parsedNumber("1E") == 1);
	assert(parsedNumber("1e+") == 1);
	assert(parsedNumber("1e-") == 1);
	assert(parsedNumber("0x1.8p") == 1.5);
	assert(parsedNumber("0x1.8P+") == 1.5);
}

unittest { // `0x` with no digits behind it is not a number at all
	bool errors;
	assert(!parses("x : compiler.byte = 0x\n", errors));
}

unittest { // a character literal is a one-character string
	auto f = makeParseFixture();
	scope(exit) f.free();
	diagnostics().clear();
	assert(parseSource(f.mod, f.builders, "c : compiler.byte_pointer = 'A'\n", "char.doir"));
	assert(!diagnostics().hasErrors());

	immutable c = resolveLookupName(f.mod, internIn(f.mod, "c"), f.root);
	assert(c != invalidEntity);
	assert(hasComponent!DString(f.mod, c));
	assert(getComponent!DString(f.mod, c).value == "A");
	diagnostics().clear();
}

unittest { // ...and an unterminated one is a syntax error
	bool errors;
	assert(!parses("c : compiler.byte_pointer = 'AB'\n", errors));
	assert(errors);
}

unittest { // string escapes survive the parser into the DString component
	auto f = makeParseFixture();
	scope(exit) f.free();
	diagnostics().clear();
	assert(parseSource(f.mod, f.builders,
		"s : compiler.byte_pointer = \"a\\tb\\x41\\101\\u0041\\U00000041\\\\\"\n", "esc.doir"));
	assert(!diagnostics().hasErrors());

	immutable s = resolveLookupName(f.mod, internIn(f.mod, "s"), f.root);
	assert(getComponent!DString(f.mod, s).value == "a\tbAAAA\\");
	diagnostics().clear();
}

unittest {
	// An escape the lexer accepts but the decoder rejects is reported, and the
	// name becomes `<error>` rather than aborting the parse.
	auto f = makeParseFixture();
	scope(exit) f.free();
	diagnostics().clear();
	// `\400` is three octal digits whose value overflows a byte... but what the
	// decoder actually rejects is a surrogate, which `stringChar` happily
	// accepts as four hex digits behind `\u`.
	assert(parseSource(f.mod, f.builders,
		"s : compiler.byte_pointer = \"\\ud800\"\n", "badesc.doir"));
	assert(diagnostics().hasErrors());
	diagnostics().clear();
}

unittest { // an escape the *lexer* rejects ends the string early, so it fails
	bool errors;
	assert(!parses("s : compiler.byte_pointer = \"\\q\"\n", errors));
	assert(!parses("s : compiler.byte_pointer = \"\\x\"\n", errors));
	assert(!parses("s : compiler.byte_pointer = \"\\u00\"\n", errors));
	assert(!parses("s : compiler.byte_pointer = \"\\U0000\"\n", errors));
	assert(!parses("s : compiler.byte_pointer = \"unterminated\n", errors));
	assert(!parses("s : compiler.byte_pointer = \"trailing\\", errors));
}

unittest { // `%"..."` quotes a name that is not a bare identifier
	auto f = makeParseFixture();
	scope(exit) f.free();
	diagnostics().clear();
	assert(parseSource(f.mod, f.builders,
		"%\"has spaces\" : compiler.byte = 1\n", "quoted.doir"));
	assert(!diagnostics().hasErrors());
	assert(resolveLookupName(f.mod, internIn(f.mod, "has spaces"), f.root) != invalidEntity);
	diagnostics().clear();
}

unittest { // an unterminated quoted identifier is a syntax error
	bool errors;
	assert(!parses("%\"unterminated : compiler.byte = 1\n", errors));
}

unittest { // `\r` and `\r\n` terminate an assignment as well as `\n`
	assert(parses("x : compiler.byte = 1\ry : compiler.byte = 2\r\n"));
}

unittest { // ...and so does end of input, with no terminator at all
	assert(parses("x : compiler.byte = 1"));
}

unittest { // a semicolon separates assignments on one line
	auto f = makeParseFixture();
	scope(exit) f.free();
	diagnostics().clear();
	assert(parseSource(f.mod, f.builders,
		"x : compiler.byte = 1;y : compiler.byte = 2\n", "semi.doir"));
	assert(!diagnostics().hasErrors());
	assert(resolveLookupName(f.mod, internIn(f.mod, "y"), f.root) != invalidEntity);
	diagnostics().clear();
}


// --- SourceInfo -------------------------------------------------------------

unittest { // `<file:line:col>` attaches a Detailed location instead of a span
	auto f = makeParseFixture();
	scope(exit) f.free();
	diagnostics().clear();
	assert(parseSource(f.mod, f.builders,
		"x : compiler.byte = 1 <other.doir:12:3>\n", "info.doir"));
	assert(!diagnostics().hasErrors());

	immutable x = resolveLookupName(f.mod, internIn(f.mod, "x"), f.root);
	assert(hasComponent!Detailed(f.mod, x));
	auto location = getComponent!Detailed(f.mod, x);
	assert(location.file == "other.doir");
	assert(location.start.line == 12);
	assert(location.start.column == 3);
	assert(location.end.line == 12);    // no end line given: same as the start
	assert(location.end.column == 4);   // no end column given: one past the start
	diagnostics().clear();
}

unittest { // the quoted-filename spelling, with explicit end line and column
	auto f = makeParseFixture();
	scope(exit) f.free();
	diagnostics().clear();
	assert(parseSource(f.mod, f.builders,
		"x : compiler.byte = 1 <\"a b.doir\":1-2:3-9>\n", "info.doir"));
	assert(!diagnostics().hasErrors());

	auto location = getComponent!Detailed(f.mod,
		resolveLookupName(f.mod, internIn(f.mod, "x"), f.root));
	assert(location.file == "a b.doir");
	assert(location.end.line == 2);
	assert(location.end.column == 9);
	diagnostics().clear();
}

unittest { // an end that comes before its start is diagnosed, on either axis
	bool errors;
	assert(parses("x : compiler.byte = 1 <a.doir:9-2:3>\n", errors));
	assert(errors);
	assert(parses("x : compiler.byte = 1 <a.doir:2:9-3>\n", errors));
	assert(errors);
}

unittest { // lines and columns are 1-based, so a 0 on either axis is diagnosed
	bool errors;
	assert(parses("x : compiler.byte = 1 <a.doir:0:3>\n", errors));
	assert(errors);
	assert(parses("x : compiler.byte = 1 <a.doir:2:0-4>\n", errors));
	assert(errors);
}

unittest {
	// `column=0` with an end column of 1 means "the whole line", which is
	// resolved by loading the named file and measuring it. A file that isn't
	// there is reported rather than guessed at.
	bool errors;
	assert(parses("x : compiler.byte = 1 <does_not_exist.doir:2:0>\n", errors));
	assert(errors);
}

unittest { // ...and a file that *is* there gives the entity that line's extent
	auto f = makeParseFixture();
	scope(exit) f.free();
	diagnostics().clear();
	// README.md is in the repo root, which is where the tests run from.
	assert(parseSource(f.mod, f.builders,
		"x : compiler.byte = 1 <README.md:2:0>\n", "info.doir"));
	assert(!diagnostics().hasErrors());

	auto location = getComponent!Detailed(f.mod,
		resolveLookupName(f.mod, internIn(f.mod, "x"), f.root));
	assert(location.start.column == 1);
	assert(location.end.column >= 1);
	diagnostics().clear();
}

unittest { // a malformed source-info suffix is simply not one, and so fails
	bool errors;
	assert(!parses("x : compiler.byte = 1 <a.doir:x:3>\n", errors)); // no line number
	assert(!parses("x : compiler.byte = 1 <a.doir:1:x>\n", errors)); // no column number
	assert(!parses("x : compiler.byte = 1 <a.doir:1:2\n", errors));  // unterminated
	assert(!parses("x : compiler.byte = 1 <a.doir 1:2>\n", errors)); // no colon after the file
	assert(!parses("x : compiler.byte = 1 <\"a.doir\" 1:2>\n", errors));
	// A `-` with no number behind it is not an end: the rule backs up over it
	// and then finds the `-` where it wanted a `:` or a `>`, so the suffix is
	// not one at all.
	assert(!parses("x : compiler.byte = 1 <a.doir:1-:2>\n", errors));
	assert(!parses("x : compiler.byte = 1 <a.doir:1:2->\n", errors));
}

unittest { // findColon and lineLength, whose corners the rule above can't reach
	assert(findColon("abc", 0) == size_t.max);
	assert(findColon("a:c", 0) == 1);
	assert(lineLength("a\nbb\nccc", 1) == 2);   // a middle line
	assert(lineLength("a\nbb\nccc", 2) == 3);   // the last, unterminated line
	assert(lineLength("a\nbb\n", 9) == 0);      // past the end
}


// --- Types and function types -----------------------------------------------

unittest { // a function type with several parameters, and with none
	assert(parses("f : type = (a: compiler.byte, b: compiler.byte) -> compiler.byte\n"));
	assert(parses("f : type = () -> compiler.byte\n"));
}

unittest { // a function type as a return type is materialised into an entity
	assert(parses("f : type = (a: compiler.byte) -> (b: compiler.byte) -> compiler.byte\n"));
}

unittest { // a trailing comma is not a parameter, so it ends the list
	bool errors;
	assert(!parses("f : type = (a: compiler.byte,) -> compiler.byte\n", errors));
}

unittest { // `deduced` parses but is reported as unsupported
	bool errors;
	assert(parses("f : type = (a: deduced compiler.byte) -> compiler.byte\n", errors));
	assert(errors);
}

unittest { // a parameter default that isn't a constant is simply not a default
	bool errors;
	assert(!parses("f : type = (a: compiler.byte = x) -> compiler.byte\n", errors));
}

unittest { // string and number parameter defaults both reach pushFunction*Parameter
	auto r = compile(
		"f : (a: compiler.byte = 3, s: compiler.byte_pointer = \"hi\") -> compiler.byte = {\n"
		~ "\t_ : compiler.byte = compiler.emit(a)\n"
		~ "}\n");
	scope(exit) freeModule(r.mod);
	assert(r.ok);
}

unittest { // ...and so does a valueless function declared with the same defaults
	assert(parses("f : (a: compiler.byte = 3, s: compiler.byte_pointer = \"hi\") -> compiler.byte\n"));
}

unittest { // a `(` that never closes is not a function type, and not an identifier
	bool errors;
	assert(!parses("f : type = (a: compiler.byte\n", errors));
	assert(!parses("f : type = (a: compiler.byte) compiler.byte\n", errors)); // no `->`
	assert(!parses("f : type = (a: compiler.byte) ->\n", errors));            // no return type
}


// --- Calls ------------------------------------------------------------------

unittest { // each of the three call modifiers sets its flag
	static immutable string[3] keywords = ["inline", "flatten", "tail"];
	static immutable ushort[3] bits = [Flags.Inline, Flags.Flatten, Flags.Tail];
	foreach (i, keyword; keywords) {
		auto f = makeParseFixture();
		scope(exit) f.free();
		diagnostics().clear();

		auto source = text("%0 : compiler.byte = 1\n%1 : compiler.byte = ",
			keyword, " compiler.emit(%0)\n");
		scope(exit) strFree(source);

		assert(parseSource(f.mod, f.builders, strSlice(source), "flags.doir"));
		assert(!diagnostics().hasErrors());
		immutable call = resolveLookupName(f.mod, internIn(f.mod, "%1"), f.root);
		assert(flagsSet(f.mod, call, bits[i]));
		diagnostics().clear();
	}
}

unittest { // a call whose argument list never closes is a syntax error
	bool errors;
	assert(!parses("%1 : compiler.byte = compiler.emit(%0\n", errors));
}

unittest { // a call through a declared function type materialises the type
	assert(parses("f : (a: compiler.byte) -> compiler.byte = compiler.emit(a)\n"));
}


// --- buildAssignment's diagnostics ------------------------------------------

unittest { // a number cannot be stored in a register whose type is a function
	bool errors;
	assert(parses("x : (a: compiler.byte) -> compiler.byte = 5\n", errors));
	assert(errors);
}

unittest { // ...nor can a string
	bool errors;
	assert(parses("x : (a: compiler.byte) -> compiler.byte = \"s\"\n", errors));
	assert(errors);
}

unittest { // a string-valued `alias` names its target by text
	auto r = compile("%1 : compiler.byte = 5\n%2 : alias = \"%1\"\n");
	scope(exit) freeModule(r.mod);
	assert(r.ok);
	assert(find(r.mod, r.root, "%2") != invalidEntity);
}

unittest { // a non-alias register cannot be assigned from a bare identifier
	bool errors;
	assert(parses("a : compiler.byte = 1\nb : compiler.byte = a\n", errors));
	assert(errors); // CantCopyRegisters: call `copy` or `move` instead
}

unittest { // the `compiler` namespace is reserved, and a redefinition is ignored
	auto f = makeParseFixture();
	scope(exit) f.free();
	diagnostics().clear();
	assert(parseSource(f.mod, f.builders,
		"compiler : namespace = {\n\tx : compiler.byte = 1\n}\n", "reserved.doir"));
	assert(!diagnostics().hasErrors()); // it is a warning, not an error
	assert(diagnostics().count() == 1);
	// The builtin `compiler.byte` is still reachable - the new block was renamed.
	assert(resolveLookupName(f.mod, internIn(f.mod, "compiler.byte"), f.root) != invalidEntity);
	diagnostics().clear();
}

unittest { // an alias may not name a block
	bool errors;
	assert(parses("x : alias = {\n\ty : compiler.byte = 1\n}\n", errors));
	assert(errors);
}

unittest { // a function type may only be assigned to a register of type `type`
	bool errors;
	assert(parses("x : compiler.byte = (a: compiler.byte) -> compiler.byte\n", errors));
	assert(errors);
	assert(parses("x : (a: compiler.byte) -> compiler.byte = (b: compiler.byte) -> compiler.byte\n", errors));
	assert(errors);
}

unittest { // a sub-block whose type is neither `type`, `namespace` nor `block`
	auto r = compile(
		"export t : type = {\n\tx : compiler.byte\n}\n"
		~ "export b : t = {\n\tx : compiler.byte = 1\n}\n");
	scope(exit) freeModule(r.mod);
	assert(r.ok);
	assert(find(r.mod, r.root, "b") != invalidEntity);
}

unittest { // `language "..." { ... }` parses, and is reported as unsupported
	bool errors;
	assert(parses("language \"c\" { int main() { return 0; } }\n", errors));
	assert(errors);
}

unittest { // ...and each way of writing it wrong is simply not a language block
	bool errors;
	assert(!parses("language \"c\n", errors));         // unterminated name
	assert(!parses("language \"c\" not_braces\n", errors)); // no braces
	assert(!parses("language \"c\" { unclosed\n", errors));
}

unittest { // `parseFile` reads a real file off disk
	diagnostics().clear();
	auto f = makeParseFixture();
	scope(exit) f.free();
	assert(parseFile(f.mod, f.builders, "test_string.doir"));
	assert(!diagnostics().hasErrors());
	assert(resolveLookupName(f.mod, internIn(f.mod, "%0"), f.root) != invalidEntity);
	diagnostics().clear();
}

unittest { // `guaranteeSourceLocation = false` leaves entities without a span
	diagnostics().clear();
	auto f = makeParseFixture();
	scope(exit) f.free();
	assert(parseSource(f.mod, f.builders, "x : compiler.byte = 1\n", "nospan.doir", false));
	assert(!diagnostics().hasErrors());

	immutable x = resolveLookupName(f.mod, internIn(f.mod, "x"), f.root);
	assert(!hasComponent!SourceLocation(f.mod, x));
	assert(!hasComponent!Detailed(f.mod, x));
	diagnostics().clear();
}

unittest {
	// `decodeAt` is the parser's own UTF-8 decoder, used to tell a Unicode
	// space apart from an identifier character. A four-byte codepoint is an
	// identifier character like any other non-space, and a byte that starts no
	// sequence at all decodes as itself rather than running off the end.
	auto f = makeParseFixture();
	scope(exit) f.free();
	diagnostics().clear();
	assert(parseSource(f.mod, f.builders,
		"\U0001F600 : compiler.byte = 1\n", "utf8.doir")); // grinning face
	assert(!diagnostics().hasErrors());
	assert(resolveLookupName(f.mod, internIn(f.mod, "\U0001F600"), f.root) != invalidEntity);
	diagnostics().clear();

	// A bare 0xFF is not a lead byte of anything.
	static immutable char[24] stray = cast(char[24]) "\xff : compiler.byte = 1\n\0";
	assert(parses(stray[0 .. 22]));
}

unittest { // a function *with a body* whose parameters carry no default value
	assert(parses(
		"export f : (a: compiler.byte) -> compiler.byte = {\n"
		~ "\t_ : compiler.byte = compiler.emit(a)\n"
		~ "}\n"));
}

unittest {
	// A parameter whose own type is a function type is materialised into an
	// entity before the function is built, so its `Lookup` arrives at
	// `pushFunctionFromType` already resolved - the other half of each of the
	// three parameter cases.
	static foreach (parameter; [
		"a: (b: compiler.byte) -> compiler.byte",          // valueless
		"a: (b: compiler.byte) -> compiler.byte = 3",      // with a number default
		"a: (b: compiler.byte) -> compiler.byte = \"hi\"", // ...and a string one
	]) {{
		auto source = text("export f : (", parameter,
			") -> compiler.byte = {\n\t_ : compiler.byte = 1\n}\n");
		scope(exit) strFree(source);
		assert(parses(strSlice(source)));
	}}
}
