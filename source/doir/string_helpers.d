/// Text building, interned strings and the arena that owns them, and the
/// C/Python string escape helpers. Ported from string_helpers.hpp.
///
/// The C++ original threw `string_processing_error` out of the un/escape
/// helpers; `-betterC` has no exceptions, so each of them takes an `out
/// StringProcessingError err` instead and reports failure through
/// `err.failed`. Every function that returns a `char*` returns a libfp
/// string the caller must `fp.string.free`.
module doir.string_helpers;

import core.stdc.string : memcpy;

static import fp.dynarray;
import fp.dynarray : daFree = free, daLength = length;
import fp.fnv1a : fnv1aHash = hash;
import fp.hashtable;
import fp.pointer : allocFunction;
import fp.string : append, appendCodepoint, decodeUtf8, isHexDigit, isOctal = isOctalDigit, strFree = free, strLength = length, strSlice = slice, Utf8Error;

/// libfp's concatenation, under the names the rest of the compiler spells it
/// with. Both take slices, fp strings and numbers alike; `text` allocates,
/// `appendText` extends what it is given.
public import fp.string : appendText = concatenateMultiple, text = createFromConcatenation;
import std.typecons : Nullable;

@nogc nothrow:


// ---------------------------------------------------------------------------
// Views
// ---------------------------------------------------------------------------

/// True if `small` points into `big`'s buffer (the C++ `doir::contains`).
///
/// Both ends have to be checked: callers subtract the two pointers to turn a
/// hit into an offset, so a `small` lying *below* `big` must not report true -
/// the subtraction would underflow into a nonsense offset (see
/// `doir.verify.getLocation`). Interned strings live in the interner's arena,
/// which is a separate allocation that routinely sits below a mapped source
/// buffer, so this is the common case rather than a corner one.
bool containsView(const(char)[] big, const(char)[] small) @trusted {
	return small.ptr >= big.ptr && small.ptr + small.length <= big.ptr + big.length;
}

/// A string that lives in a `StringInterner`'s arena. Two interned strings
/// are equal exactly when they are the same allocation, which is what makes
/// the whole compiler's name comparisons pointer comparisons.
///
/// The C++ version derived from `std::string_view` and overrode `operator==`
/// to compare `data()`; here the slice is a field, with `view` for the
/// content and `opEquals` for the identity comparison.
struct InternedString {
	const(char)[] view;

	@nogc nothrow:

	this(const(char)[] v) { view = v; }

	/// Identity comparison - the point of interning.
	bool opEquals(const InternedString o) const @trusted {
		return view.ptr is o.view.ptr && view.length == o.view.length;
	}

	/// Content comparison against a raw slice, for the handful of places
	/// that compare against a literal rather than against another interned
	/// string.
	bool opEquals(const(char)[] o) const @trusted {
		import core.stdc.string : memcmp;
		return view.length == o.length
			&& (view.length == 0 || memcmp(view.ptr, o.ptr, view.length) == 0);
	}

	char opIndex(size_t i) const { return view[i]; }
}

/// The `_` name, which `pushCommon` treats as "don't attach a name".
InternedString wildcardName() { return InternedString("_"); }


// ---------------------------------------------------------------------------
// String interner
// ---------------------------------------------------------------------------

/// One entry of the interner's lookup table. Stored as a plain slice so the
/// custom hash/equal functions below can reinterpret the raw bytes.
private struct InternEntry {
	const(char)[] text;
}

private size_t internHash(inout(ubyte)[] data) @trusted {
	auto e = cast(const(InternEntry)*) data.ptr;
	return fnv1aHash(cast(inout(ubyte)[]) e.text);
}

private bool internEqual(inout(ubyte)[] a, inout(ubyte)[] b) @trusted {
	import core.stdc.string : memcmp;
	auto ea = cast(const(InternEntry)*) a.ptr;
	auto eb = cast(const(InternEntry)*) b.ptr;
	if (ea.text.length != eb.text.length) return false;
	if (ea.text.length == 0) return true;
	return memcmp(ea.text.ptr, eb.text.ptr, ea.text.length) == 0;
}

/// A bump allocator handing out never-moving, NUL-terminated copies of every
/// distinct string it is shown, plus the table that makes the copies unique.
///
/// Plain data with free functions, matching the ecrs/fp house style: create
/// it with `createInterner`, release it with `free`.
struct StringInterner {
	size_t blockSize = 4096;
	size_t offset = 0;
	char** blocks = null; // fp dynarray of owned blocks
	InternEntry* table = null;
}

StringInterner createInterner(size_t blockSize = 4096) @trusted {
	assert(blockSize > 0, "block_size must be positive");
	StringInterner self;
	self.blockSize = blockSize;
	self.table = fp.hashtable.create!InternEntry(Config(&internHash, &internEqual));
	addBlock(self, 0);
	return self;
}

void free(ref StringInterner self) @trusted {
	if (self.blocks !is null) {
		foreach (i; 0 .. daLength(self.blocks))
			allocFunction(self.blocks[i], 0);
		daFree(self.blocks);
	}
	if (self.table !is null) fp.hashtable.free(self.table);
}

private void addBlock(ref StringInterner self, size_t size) @trusted {
	immutable n = size ? size : self.blockSize;
	auto block = cast(char*) allocFunction(null, n);
	assert(block !is null);
	fp.dynarray.pushBack(self.blocks, block);
	self.offset = 0;
}

private const(char)* allocateText(ref StringInterner self, const(char)[] s) @trusted {
	immutable n = s.length + 1; // +1 for the NUL terminator

	if (self.offset + n > self.blockSize)
		addBlock(self, self.blockSize > n ? self.blockSize : n);

	char* dst = self.blocks[daLength(self.blocks) - 1] + self.offset;
	if (s.length) memcpy(dst, s.ptr, s.length);
	dst[s.length] = '\0';
	self.offset += n;
	return dst;
}

/// Returns the canonical copy of `s`, allocating one the first time it is seen.
InternedString intern(ref StringInterner self, const(char)[] s) @trusted {
	auto probe = InternEntry(s);
	if (auto found = fp.hashtable.find(self.table, probe))
		return InternedString(found.text);

	auto p = allocateText(self, s);
	auto interned = InternedString(p[0 .. s.length]);
	fp.hashtable.insertAssumeUnique(self.table, InternEntry(interned.view));
	return interned;
}

/// Looks `s` up without interning it, or null if it isn't present. A null
/// result and an interned empty string are different answers, which is why
/// this is a `Nullable` rather than an `InternedString(null)` sentinel.
Nullable!InternedString findInterned(ref StringInterner self, const(char)[] s) @trusted {
	auto probe = InternEntry(s);
	if (auto hit = fp.hashtable.find(self.table, probe))
		return Nullable!InternedString(InternedString(hit.text));
	return Nullable!InternedString.init;
}


// ---------------------------------------------------------------------------
// Escape / unescape
// ---------------------------------------------------------------------------

/// Stands in for the C++ `string_processing_error` exception.
struct StringProcessingError {
	bool failed = false;
	const(char)[] message;
	size_t start;
}

private void fail(ref StringProcessingError err, const(char)[] message, size_t start) {
	if (err.failed) return;
	err.failed = true;
	err.message = message;
	err.start = start;
}

/// `fp.string.appendCodepoint`, with the refusal turned into a diagnostic.
/// Only the wording is ours; the encoding lives in libfp.
private void appendUtf8(ref char* outStr, uint cp, ref StringProcessingError err) @trusted {
	immutable why = appendCodepoint(outStr, cp);
	if (why == Utf8Error.none) return;
	fail(err, why == Utf8Error.surrogate
		? "Invalid Unicode code point (surrogate range)"
		: "Unicode code point out of range", strLength(outStr));
}

private uint hexDigit(char c, ref StringProcessingError err) {
	if ('0' <= c && c <= '9') return c - '0';
	if ('a' <= c && c <= 'f') return c - 'a' + 10;
	if ('A' <= c && c <= 'F') return c - 'A' + 10;
	fail(err, "Invalid hex digit", 0);
	return 0;
}

private immutable string hexChars = "0123456789abcdef";

private void appendHexEscape(ref char* outStr, ubyte c) @trusted {
	append(outStr, '\\');
	append(outStr, 'x');
	append(outStr, hexChars[(c >> 4) & 0xF]);
	append(outStr, hexChars[c & 0xF]);
}

private void appendUnicodeEscape(ref char* outStr, uint cp) @trusted {
	append(outStr, '\\');
	if (cp <= 0xFFFF) {
		append(outStr, 'u');
		for (int shift = 12; shift >= 0; shift -= 4)
			append(outStr, hexChars[(cp >> shift) & 0xF]);
	} else {
		append(outStr, 'U');
		for (int shift = 28; shift >= 0; shift -= 4)
			append(outStr, hexChars[(cp >> shift) & 0xF]);
	}
}

/// Decodes Python-style escapes. Returns a libfp string; free it with
/// `fp.string.free`. On failure `err.failed` is set and the partial result
/// is still returned (and must still be freed), matching how the caller in
/// the parser reports the error and substitutes `<error>`.
/// `\0` - `\777`: up to three octal digits, low eight bits kept. Leaves `i` on
/// the last digit consumed.
private void appendOctalEscape(ref char* outStr, const(char)[] literal, ref size_t i,
		char esc) @trusted {
	uint v = cast(uint)(esc - '0');
	foreach (_; 0 .. 2) {
		if (i + 1 < literal.length && isOctal(literal[i + 1]))
			v = (v << 3) | cast(uint)(literal[++i] - '0');
		else break;
	}
	append(outStr, cast(char) cast(ubyte) v);
}

/// Reads exactly `digits` hex digits following `literal[i]`, appends the
/// codepoint they name and leaves `i` on the last of them. `truncated` is the
/// diagnostic for a literal that ends first. False once `err` is set.
///
/// The range check is `\U`'s - four digits cannot exceed 0xFFFF - and is kept
/// here so it reports at `i`, the escape, rather than at the output length the
/// encoder would name.
private bool appendHexCodepoint(ref char* outStr, const(char)[] literal, ref size_t i,
		size_t digits, const(char)[] truncated, ref StringProcessingError err) @trusted {
	if (i + digits >= literal.length) {
		fail(err, truncated, i);
		return false;
	}
	uint cp = 0;
	foreach (_; 0 .. digits)
		cp = (cp << 4) | hexDigit(literal[++i], err);
	if (err.failed) return false;
	if (cp > 0x10FFFF) {
		fail(err, "Unicode code point out of range", i);
		return false;
	}
	appendUtf8(outStr, cp, err);
	return !err.failed;
}

char* unescapePythonString(const(char)[] literal, out StringProcessingError err) @trusted {
	char* outStr = null;

	for (size_t i = 0; i < literal.length; ++i) {
		immutable c = literal[i];

		if (c != '\\') {
			append(outStr, c);
			continue;
		}

		if (++i >= literal.length) {
			fail(err, "Trailing backslash in string", i);
			return outStr;
		}

		immutable esc = literal[i];
		switch (esc) {
			case '\n': break; // line continuation
			case '\\': append(outStr, '\\'); break;
			case '\'': append(outStr, '\''); break;
			case '"': append(outStr, '"'); break;
			case 'a': append(outStr, '\a'); break;
			case 'b': append(outStr, '\b'); break;
			case 'f': append(outStr, '\f'); break;
			case 'n': append(outStr, '\n'); break;
			case 'r': append(outStr, '\r'); break;
			case 't': append(outStr, '\t'); break;
			case 'v': append(outStr, '\v'); break;

			case 'x': // \xhh
				if (i + 2 >= literal.length) {
					fail(err, "Invalid \\x escape: insufficient characters", i);
					return outStr;
				}
				immutable hi = hexDigit(literal[++i], err);
				immutable v = (hi << 4) | hexDigit(literal[++i], err);
				if (err.failed) return outStr;
				append(outStr, cast(char) v);
				break;

			case 'u': // \uXXXX
				if (!appendHexCodepoint(outStr, literal, i, 4,
					"Invalid \\u escape: insufficient characters", err)) return outStr;
				break;

			case 'U': // \UXXXXXXXX
				if (!appendHexCodepoint(outStr, literal, i, 8,
					"Invalid \\U escape: insufficient characters", err)) return outStr;
				break;

			default:
				if (!isOctal(esc)) {
					fail(err, "Invalid escape sequence", i);
					return outStr;
				}
				appendOctalEscape(outStr, literal, i, esc);
		}
	}

	return outStr;
}

/// Re-encodes `input` with Python-style escapes. Returns a libfp string.
char* escapePythonString(const(char)[] input) @trusted {
	char* outStr = null;

	for (size_t i = 0; i < input.length;) {
		immutable c = cast(ubyte) input[i];

		// ASCII fast path
		if (c < 0x80) {
			++i;
			switch (c) {
				case '\\': append(outStr, '\\'); append(outStr, '\\'); break;
				case '\'': append(outStr, '\\'); append(outStr, '\''); break;
				case '"': append(outStr, '\\'); append(outStr, '"'); break;
				case '\a': append(outStr, '\\'); append(outStr, 'a'); break;
				case '\b': append(outStr, '\\'); append(outStr, 'b'); break;
				case '\f': append(outStr, '\\'); append(outStr, 'f'); break;
				case '\n': append(outStr, '\\'); append(outStr, 'n'); break;
				case '\r': append(outStr, '\\'); append(outStr, 'r'); break;
				case '\t': append(outStr, '\\'); append(outStr, 't'); break;
				case '\v': append(outStr, '\\'); append(outStr, 'v'); break;
				default:
					if (c >= 0x20 && c <= 0x7E) append(outStr, cast(char) c);
					else appendHexEscape(outStr, c);
			}
		} else {
			appendUnicodeEscape(outStr, decodeUtf8(input, i));
		}
	}

	return outStr;
}

/// Decodes C++-style escapes. Returns a libfp string.
char* unescapeCppString(const(char)[] literal, out StringProcessingError err) @trusted {
	char* outStr = null;

	for (size_t i = 0; i < literal.length; ++i) {
		immutable c = literal[i];

		if (c != '\\') {
			append(outStr, c);
			continue;
		}

		if (++i >= literal.length) {
			fail(err, "Trailing backslash in string", i);
			return outStr;
		}

		immutable esc = literal[i];
		switch (esc) {
			case '\\': append(outStr, '\\'); break;
			case '\'': append(outStr, '\''); break;
			case '"': append(outStr, '"'); break;
			case 'a': append(outStr, '\a'); break;
			case 'b': append(outStr, '\b'); break;
			case 'f': append(outStr, '\f'); break;
			case 'n': append(outStr, '\n'); break;
			case 'r': append(outStr, '\r'); break;
			case 't': append(outStr, '\t'); break;
			case 'v': append(outStr, '\v'); break;

			case 'x': { // \xh[h...] - one or more hex digits, low 8 bits kept
				if (i + 1 >= literal.length || !isHexDigit(literal[i + 1])) {
					fail(err, "Invalid \\x escape: no hex digit follows", i);
					return outStr;
				}
				uint v = 0;
				while (i + 1 < literal.length && isHexDigit(literal[i + 1]))
					v = (v << 4) | hexDigit(literal[++i], err);
				if (err.failed) return outStr;
				append(outStr, cast(char) cast(ubyte) v);
				break;
			}

			case 'u': // \uXXXX
				if (!appendHexCodepoint(outStr, literal, i, 4,
					"Invalid \\u escape: insufficient characters", err)) return outStr;
				break;

			case 'U': // \UXXXXXXXX
				if (!appendHexCodepoint(outStr, literal, i, 8,
					"Invalid \\U escape: insufficient characters", err)) return outStr;
				break;

			default:
				if (!isOctal(esc)) {
					fail(err, "Invalid C++ escape sequence", i);
					return outStr;
				}
				appendOctalEscape(outStr, literal, i, esc);
		}
	}

	return outStr;
}

/// Re-encodes `input` with C++-style escapes. Returns a libfp string.
char* escapeCppString(const(char)[] input) @trusted {
	char* outStr = null;
	bool needsSplice = false; // set when the last emission was \xhh

	foreach (i; 0 .. input.length) {
		immutable c = cast(ubyte) input[i];

		// Close and reopen the literal so the next hex digit is not absorbed
		// into the preceding \xhh escape.
		if (needsSplice && isHexDigit(cast(char) c)) {
			append(outStr, '"');
			append(outStr, ' ');
			append(outStr, '"');
		}
		needsSplice = false;

		if (c >= 0x20 && c <= 0x7E) {
			switch (c) {
				case '\\': append(outStr, '\\'); append(outStr, '\\'); break;
				case '"': append(outStr, '\\'); append(outStr, '"'); break;
				case '\'': append(outStr, '\\'); append(outStr, '\''); break;
				case '?': append(outStr, '\\'); append(outStr, '?'); break; // avoid trigraphs
				default: append(outStr, cast(char) c); break;
			}
		} else {
			switch (c) {
				// `\0` is an octal escape, so a digit right behind it would be
				// absorbed into it the same way a hex digit is absorbed into
				// `\xhh`; splice the literal there too. (Every octal digit is
				// also a hex digit, so the `isHexDigit` test below covers it.)
				case '\0':
					append(outStr, '\\');
					append(outStr, '0');
					needsSplice = true;
					break;
				case '\a': append(outStr, '\\'); append(outStr, 'a'); break;
				case '\b': append(outStr, '\\'); append(outStr, 'b'); break;
				case '\f': append(outStr, '\\'); append(outStr, 'f'); break;
				case '\n': append(outStr, '\\'); append(outStr, 'n'); break;
				case '\r': append(outStr, '\\'); append(outStr, 'r'); break;
				case '\t': append(outStr, '\\'); append(outStr, 't'); break;
				case '\v': append(outStr, '\\'); append(outStr, 'v'); break;
				default:
					appendHexEscape(outStr, c);
					needsSplice = true;
					break;
			}
		}
	}

	return outStr;
}

/// Replaces every occurrence of `needle` in the libfp string `haystack`.
/// Empty needles are ignored, as in the C++ original (which would otherwise
/// loop forever).
void replaceAll(ref char* haystack, const(char)[] needle, const(char)[] replacement) @trusted {
	import fp.string : replaceSlices;
	if (needle.length == 0) return;
	replaceSlices(haystack, needle, replacement, 0);
}


// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
// Ported from tests/interned_string.test.cpp.

version (unittest) {
	private alias Unescaper = char* function(const(char)[], out StringProcessingError) @nogc nothrow;

	/// Each (literal, expected) pair must decode cleanly to `expected`.
	private void decodesTo(Unescaper decode, const(char)[][] pairs...) {
		assert(pairs.length % 2 == 0);
		for (size_t i = 0; i < pairs.length; i += 2) {
			StringProcessingError err;
			auto decoded = decode(pairs[i], err);
			scope(exit) strFree(decoded);
			assert(!err.failed, pairs[i]);
			assert((decoded is null ? "" : strSlice(decoded)) == pairs[i + 1], pairs[i]);
		}
	}

	/// Every literal must fail to decode, reporting through `err`.
	private void decodeFails(Unescaper decode, const(char)[][] literals...) {
		foreach (l; literals) {
			StringProcessingError err;
			auto decoded = decode(l, err);
			scope(exit) strFree(decoded); // the partial result still has to be freed
			assert(err.failed, l);
			assert(err.message.length > 0, l);
		}
	}

	/// Each (input, expected) pair must escape to `expected`.
	private void escapesTo(char* function(const(char)[]) @nogc nothrow escape,
			const(char)[][] pairs...) {
		assert(pairs.length % 2 == 0);
		for (size_t i = 0; i < pairs.length; i += 2) {
			auto escaped = escape(pairs[i]);
			scope(exit) strFree(escaped);
			assert(strSlice(escaped) == pairs[i + 1], pairs[i]);
		}
	}
}

unittest { // interning equal content twice returns the same backing pointer
	auto interner = createInterner();
	scope(exit) free(interner);
	auto a = intern(interner, "hello");
	auto b = intern(interner, "hello");
	assert(a.view.ptr is b.view.ptr);
	assert(a == b); // InternedString.opEquals is pointer identity
}

unittest { // interning distinct content returns distinct pointers
	auto interner = createInterner();
	scope(exit) free(interner);
	auto a = intern(interner, "hello");
	auto b = intern(interner, "world");
	assert(a.view.ptr !is b.view.ptr);
	assert(a != b);
}

unittest { // interning the empty string does not crash and round trips
	auto interner = createInterner();
	scope(exit) free(interner);
	auto empty = intern(interner, "");
	assert(empty.view.length == 0);

	auto looked = findInterned(interner, "");
	assert(!looked.isNull);
	assert(looked.get.view.length == 0);
}

unittest { // find reports nothing for strings that were never interned
	auto interner = createInterner();
	scope(exit) free(interner);
	intern(interner, "hello");

	assert(findInterned(interner, "does_not_exist").isNull);
}

unittest { // allocation spans multiple blocks once the block size is exceeded
	auto interner = createInterner(8); // tiny block size forces multiple blocks
	scope(exit) free(interner);
	auto a = intern(interner, "this string is longer than one block");
	auto b = intern(interner, "so is this second one, also long");
	assert(a.view == "this string is longer than one block");
	assert(b.view == "so is this second one, also long");
}

unittest {
	// Content-equal interned strings from *different* interners compare unequal.
	// InternedString.opEquals is pointer identity, not content comparison. This
	// is fine as long as both sides always come from the same interner (which
	// `Module` guarantees per-module), but it is a sharp edge.
	auto a = createInterner();
	scope(exit) free(a);
	auto b = createInterner();
	scope(exit) free(b);

	auto sa = intern(a, "shared_name");
	auto sb = intern(b, "shared_name");

	assert(sa.view == sb.view); // content is identical
	assert(sa != sb);           // but identity comparison says otherwise
}

unittest {
	// `InternedString.wildcard` is a standalone literal, never produced by
	// `intern`. Comparing it against an interned "_" therefore fails the
	// pointer-identity opEquals even though the text is identical - code that
	// needs to recognize the discard name must compare content.
	auto interner = createInterner();
	scope(exit) free(interner);
	auto underscore = intern(interner, "_");
	assert(underscore.view == wildcardName().view);
	assert(underscore != wildcardName());
}

unittest { // an interned string compares to a plain slice by content
	auto interner = createInterner();
	scope(exit) free(interner);
	auto interned = intern(interner, "hello");
	assert(interned == "hello");
}

unittest {
	// `containsView` has to reject a slice that lies *below* `big`, not just
	// one that runs off the end. Callers turn a hit into an offset by
	// subtracting the two pointers, so a false positive here underflows into a
	// nonsense offset - `doir.verify.getLocation` built an out-of-range
	// SourceLocation out of it and tripped an assertion inside libdiagnose.
	static immutable char[8] buffer = "abcdefgh";
	auto whole = buffer[0 .. $];

	assert(containsView(whole, buffer[0 .. 8]));  // the whole thing
	assert(containsView(whole, buffer[2 .. 5]));  // strictly inside
	assert(!containsView(whole, buffer[0 .. 8].ptr[0 .. 9])); // runs off the end

	// One byte short of `whole`'s start: not contained, either end.
	auto below = buffer[0 .. 8].ptr[0 .. 4];
	assert(containsView(below, below));
	assert(!containsView(buffer[4 .. 8], below));
}

unittest {
	// A string literal can hold a truncated UTF-8 sequence (`"\\xE2"` decodes
	// to one lead byte with no continuation bytes behind it), and `print`
	// re-escapes every string it emits. The decoder must not read the
	// continuation bytes the lead byte promises without checking they exist.
	static immutable char[1] truncated = [cast(char) 0xE2];
	auto escaped = escapePythonString(truncated[0 .. 1]);
	scope(exit) strFree(escaped);
	assert(escaped !is null);
	assert(strSlice(escaped) == "\\u00e2");
}

unittest { // a well-formed multi-byte codepoint still round trips
	StringProcessingError err;
	auto decoded = unescapePythonString("\\u00e9", err); // e-acute
	scope(exit) strFree(decoded);
	assert(!err.failed);
	assert(strSlice(decoded) == "\xc3\xa9");

	auto reescaped = escapePythonString(strSlice(decoded));
	scope(exit) strFree(reescaped);
	assert(strSlice(reescaped) == "\\u00e9");
}

unittest {
	// `\0` is an octal escape, so a digit directly behind it would be absorbed
	// into it: emitting `\0` then `1` as `"\01"` says octal 1, not NUL followed
	// by '1'. `escapeCppString` has to splice the literal there, exactly as it
	// already did after a `\xhh`.
	static immutable char[2] nulThenDigit = [cast(char) 0, '1'];
	auto escaped = escapeCppString(nulThenDigit[0 .. 2]);
	scope(exit) strFree(escaped);
	assert(strSlice(escaped) == "\\0\" \"1");

	// A NUL followed by a non-digit needs no splice.
	static immutable char[2] nulThenLetter = [cast(char) 0, 'z'];
	auto plain = escapeCppString(nulThenLetter[0 .. 2]);
	scope(exit) strFree(plain);
	assert(strSlice(plain) == "\\0z");
}

// NOTE: the C++ suite also asserted `string_interner(0)` throws
// `std::invalid_argument`. `-betterC` has no exceptions; `createInterner`
// asserts instead, which cannot be caught and so cannot be tested here.

// --- Escape / unescape ------------------------------------------------------
//
// The un/escape helpers are the compiler's only string-literal codec: the
// parser runs every `"..."` it sees through `unescapePythonString`, and
// `doir.print` runs every string it emits back through `escapePythonString`.
// Both directions are exercised here, including the failure paths, which
// `-betterC` reports through `StringProcessingError` rather than by throwing.

unittest { // what the Python unescaper decodes
	decodesTo(&unescapePythonString,
		// every simple escape, to the byte it names
		"\\\\", "\\",  "\\'", "'",  "\\\"", "\"",  "\\a", "\a",  "\\b", "\b",  "\\f", "\f",
		"\\n", "\n",  "\\r", "\r",  "\\t", "\t",  "\\v", "\v",  "\\\n", "", // line continuation
		"plain text", "plain text",       // a plain character passes through
		"\\x41\\xfF", "A\xff",            // \xhh, in both digit cases
		"\\101\\78", "A\x078",            // octal: up to three digits, stopping at a non-octal
		"\\u0041\\u00e9", "A\xc3\xa9",    // \u, one- and two-byte
		"\\u20ac", "\xe2\x82\xac",        // a BMP codepoint above 0x7FF is three bytes
		"\\U0001F600", "\xf0\x9f\x98\x80"); // \U past the BMP is four
}

unittest { // every way a Python escape can fail reports through `err`
	decodeFails(&unescapePythonString,
		"\\",          // trailing backslash
		"\\q",         // not an escape at all
		"\\x",         // \x with nothing behind it
		"\\xzz",       // ...or with non-hex digits
		"\\u00",       // \u truncated
		"\\U0000",     // \U truncated
		"\\UFFFFFFFF", // out of Unicode range
		"\\ud800");    // a surrogate half is never legal in UTF-8
}

unittest { // `fail` keeps the *first* error rather than the last
	StringProcessingError err;
	fail(err, "first", 1);
	fail(err, "second", 2);
	assert(err.failed);
	assert(err.message == "first");
	assert(err.start == 1);
}

unittest { // hexDigit covers all three digit ranges, and reports the rest
	StringProcessingError ok;
	assert(hexDigit('7', ok) == 7);
	assert(hexDigit('c', ok) == 12);
	assert(hexDigit('C', ok) == 12);
	assert(!ok.failed);

	StringProcessingError bad;
	assert(hexDigit('g', bad) == 0);
	assert(bad.failed);
}

unittest { // escapePythonString is the inverse for everything it can name
	static immutable char[1] control = [cast(char) 0x01];
	escapesTo(&escapePythonString,
		"\\", "\\\\",  "'", "\\'",  "\"", "\\\"",  "\a", "\\a",  "\b", "\\b",  "\f", "\\f",
		"\n", "\\n",  "\r", "\\r",  "\t", "\\t",  "\v", "\\v",
		"Az09 ~", "Az09 ~",              // printable ASCII stays literal
		control[0 .. 1], "\\x01",        // anything else below 0x80 goes to \xhh
		"\xf0\x9f\x98\x80", "\\U0001f600"); // past the BMP escapes as \U, not \u
}

unittest { // the C++ escaper names the same set, and hex-escapes the rest
	escapesTo(&escapeCppString,
		"\\", "\\\\",  "\"", "\\\"",  "'", "\\'",  "?", "\\?",  "\a", "\\a",  "\b", "\\b",
		"\f", "\\f",  "\n", "\\n",  "\r", "\\r",  "\t", "\\t",  "\v", "\\v",
		"ok", "ok");
}

unittest {
	// A `\xhh` escape is greedy in C++, so a hex digit directly behind one
	// would be absorbed into it; the literal is spliced there, exactly as it
	// is after a `\0`.
	static immutable char[2] highThenHex = [cast(char) 0x80, 'a'];
	auto escaped = escapeCppString(highThenHex[0 .. 2]);
	scope(exit) strFree(escaped);
	assert(strSlice(escaped) == "\\x80\" \"a");

	static immutable char[2] highThenLetter = [cast(char) 0x80, 'z'];
	auto plain = escapeCppString(highThenLetter[0 .. 2]);
	scope(exit) strFree(plain);
	assert(strSlice(plain) == "\\x80z");
}

unittest { // the C++ unescaper accepts everything the Python one does
	decodesTo(&unescapeCppString,
		"\\\\\\'\\\"\\a\\b\\f\\n\\r\\t\\v\\x41\\u0041\\U00000041\\101\\78",
		"\\'\"\a\b\f\n\r\t\vAAAA\x078",
		"\\x141", "\x41"); // its \x is greedy, keeping only the low byte
}

unittest { // ...and it reports the same failures
	decodeFails(&unescapeCppString, "\\", "\\q", "\\x", "\\xz", "\\u00", "\\UFFFFFFFF",
		"\\udc00",   // a surrogate, rejected by the encoder rather than the lexer
		"\\U0000");  // \U needs all eight digits present
}

unittest { // replaceAll rewrites every occurrence, and ignores an empty needle
	auto s = escapePythonString("a-b-c");
	scope(exit) strFree(s);
	replaceAll(s, "-", "+");
	assert(strSlice(s) == "a+b+c");

	replaceAll(s, "", "!"); // would loop forever if it were honored
	assert(strSlice(s) == "a+b+c");
}
