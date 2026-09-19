/// Interned strings, the arena that owns them, and the C/Python string
/// escape helpers. Ported from string_helpers.hpp.
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
import fp.string : concatenateSlice, strFree = free, strLength = length, strSlice = slice;
import std.typecons : Nullable;

/// libfp's own `append` asserts the string is already allocated, so this
/// null-safe one-character append stands in for it throughout.
private void strAppend(ref char* s, char c) @trusted @nogc nothrow {
	concatenateSlice(s, (&c)[0 .. 1]);
}

@nogc nothrow:


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
		return view.length == o.length
			&& (view.length == 0 || memcmpWrapper(view.ptr, o.ptr, view.length) == 0);
	}

	char opIndex(size_t i) const { return view[i]; }
}

/// The `_` name, which `pushCommon` treats as "don't attach a name".
InternedString wildcardName() { return InternedString("_"); }

private int memcmpWrapper(const(char)* a, const(char)* b, size_t n) @trusted {
	import core.stdc.string : memcmp;
	return memcmp(a, b, n);
}


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
	auto ea = cast(const(InternEntry)*) a.ptr;
	auto eb = cast(const(InternEntry)*) b.ptr;
	if (ea.text.length != eb.text.length) return false;
	if (ea.text.length == 0) return true;
	return memcmpWrapper(ea.text.ptr, eb.text.ptr, ea.text.length) == 0;
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

private void appendUtf8(ref char* outStr, uint cp, ref StringProcessingError err) @trusted {
	if (cp > 0x10FFFF) {
		fail(err, "Unicode code point out of range", strLength(outStr));
		return;
	}
	// UTF-16 surrogate pairs (0xD800-0xDFFF) are invalid in UTF-8
	if (cp >= 0xD800 && cp <= 0xDFFF) {
		fail(err, "Invalid Unicode code point (surrogate range)", strLength(outStr));
		return;
	}

	if (cp <= 0x7F) {
		strAppend(outStr, cast(char) cp);
	} else if (cp <= 0x7FF) {
		strAppend(outStr, cast(char)(0xC0 | (cp >> 6)));
		strAppend(outStr, cast(char)(0x80 | (cp & 0x3F)));
	} else if (cp <= 0xFFFF) {
		strAppend(outStr, cast(char)(0xE0 | (cp >> 12)));
		strAppend(outStr, cast(char)(0x80 | ((cp >> 6) & 0x3F)));
		strAppend(outStr, cast(char)(0x80 | (cp & 0x3F)));
	} else {
		strAppend(outStr, cast(char)(0xF0 | (cp >> 18)));
		strAppend(outStr, cast(char)(0x80 | ((cp >> 12) & 0x3F)));
		strAppend(outStr, cast(char)(0x80 | ((cp >> 6) & 0x3F)));
		strAppend(outStr, cast(char)(0x80 | (cp & 0x3F)));
	}
}

private uint hexDigit(char c, ref StringProcessingError err) {
	if ('0' <= c && c <= '9') return c - '0';
	if ('a' <= c && c <= 'f') return c - 'a' + 10;
	if ('A' <= c && c <= 'F') return c - 'A' + 10;
	fail(err, "Invalid hex digit", 0);
	return 0;
}

private bool isOctal(char c) { return c >= '0' && c <= '7'; }

private bool isHexDigit(char c) {
	return ('0' <= c && c <= '9') || ('a' <= c && c <= 'f') || ('A' <= c && c <= 'F');
}

private immutable string hexChars = "0123456789abcdef";

private void appendHexEscape(ref char* outStr, ubyte c) @trusted {
	strAppend(outStr, '\\');
	strAppend(outStr, 'x');
	strAppend(outStr, hexChars[(c >> 4) & 0xF]);
	strAppend(outStr, hexChars[c & 0xF]);
}

private void appendUnicodeEscape(ref char* outStr, uint cp) @trusted {
	strAppend(outStr, '\\');
	if (cp <= 0xFFFF) {
		strAppend(outStr, 'u');
		for (int shift = 12; shift >= 0; shift -= 4)
			strAppend(outStr, hexChars[(cp >> shift) & 0xF]);
	} else {
		strAppend(outStr, 'U');
		for (int shift = 28; shift >= 0; shift -= 4)
			strAppend(outStr, hexChars[(cp >> shift) & 0xF]);
	}
}

/// Minimal UTF-8 decoder.
///
/// The continuation bytes a lead byte promises are checked against the end of
/// `s` before they are read: `escapePythonString` runs over whatever bytes the
/// program being compiled put in a string literal, and `"\\xE2"` is a lead byte
/// with nothing behind it. A truncated (or otherwise malformed) sequence
/// decodes as the lead byte itself, consuming one byte, so the caller always
/// makes progress and never reads past the slice.
private uint decodeUtf8(const(char)[] s, ref size_t i) @trusted {
	immutable c = cast(ubyte) s[i];

	if (c < 0x80) {
		return cast(uint) s[i++];
	} else if ((c >> 5) == 0x6 && i + 1 < s.length) {
		immutable cp = ((c & 0x1F) << 6) | (cast(ubyte) s[i + 1] & 0x3F);
		i += 2;
		return cp;
	} else if ((c >> 4) == 0xE && i + 2 < s.length) {
		immutable cp = ((c & 0x0F) << 12)
			| ((cast(ubyte) s[i + 1] & 0x3F) << 6)
			| (cast(ubyte) s[i + 2] & 0x3F);
		i += 3;
		return cp;
	} else if ((c >> 3) == 0x1E && i + 3 < s.length) {
		immutable cp = ((c & 0x07) << 18)
			| ((cast(ubyte) s[i + 1] & 0x3F) << 12)
			| ((cast(ubyte) s[i + 2] & 0x3F) << 6)
			| (cast(ubyte) s[i + 3] & 0x3F);
		i += 4;
		return cp;
	} else {
		++i;
		return c;
	}
}

/// Decodes Python-style escapes. Returns a libfp string; free it with
/// `fp.string.free`. On failure `err.failed` is set and the partial result
/// is still returned (and must still be freed), matching how the caller in
/// the parser reports the error and substitutes `<error>`.
char* unescapePythonString(const(char)[] literal, out StringProcessingError err) @trusted {
	char* outStr = null;

	for (size_t i = 0; i < literal.length; ++i) {
		immutable c = literal[i];

		if (c != '\\') {
			strAppend(outStr, c);
			continue;
		}

		if (++i >= literal.length) {
			fail(err, "Trailing backslash in string", i);
			return outStr;
		}

		immutable esc = literal[i];
		switch (esc) {
			case '\n': break; // line continuation
			case '\\': strAppend(outStr, '\\'); break;
			case '\'': strAppend(outStr, '\''); break;
			case '"': strAppend(outStr, '"'); break;
			case 'a': strAppend(outStr, '\a'); break;
			case 'b': strAppend(outStr, '\b'); break;
			case 'f': strAppend(outStr, '\f'); break;
			case 'n': strAppend(outStr, '\n'); break;
			case 'r': strAppend(outStr, '\r'); break;
			case 't': strAppend(outStr, '\t'); break;
			case 'v': strAppend(outStr, '\v'); break;

			case 'x': // \xhh
				if (i + 2 >= literal.length) {
					fail(err, "Invalid \\x escape: insufficient characters", i);
					return outStr;
				}
				immutable hi = hexDigit(literal[++i], err);
				immutable v = (hi << 4) | hexDigit(literal[++i], err);
				if (err.failed) return outStr;
				strAppend(outStr, cast(char) v);
				break;

			case 'u': { // \uXXXX
				if (i + 4 >= literal.length) {
					fail(err, "Invalid \\u escape: insufficient characters", i);
					return outStr;
				}
				uint cp = 0;
				foreach (_; 0 .. 4)
					cp = (cp << 4) | hexDigit(literal[++i], err);
				if (err.failed) return outStr;
				appendUtf8(outStr, cp, err);
				if (err.failed) return outStr;
				break;
			}

			case 'U': { // \UXXXXXXXX
				if (i + 8 >= literal.length) {
					fail(err, "Invalid \\U escape: insufficient characters", i);
					return outStr;
				}
				uint cp = 0;
				foreach (_; 0 .. 8)
					cp = (cp << 4) | hexDigit(literal[++i], err);
				if (err.failed) return outStr;
				if (cp > 0x10FFFF) {
					fail(err, "Unicode code point out of range", i);
					return outStr;
				}
				appendUtf8(outStr, cp, err);
				if (err.failed) return outStr;
				break;
			}

			default:
				if (isOctal(esc)) {
					// \0 - \777 (up to 3 digits)
					uint v = esc - '0';
					foreach (_; 0 .. 2) {
						if (i + 1 < literal.length && isOctal(literal[i + 1]))
							v = (v << 3) | (literal[++i] - '0');
						else break;
					}
					strAppend(outStr, cast(char) v);
				} else {
					fail(err, "Invalid escape sequence", i);
					return outStr;
				}
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
				case '\\': strAppend(outStr, '\\'); strAppend(outStr, '\\'); break;
				case '\'': strAppend(outStr, '\\'); strAppend(outStr, '\''); break;
				case '"': strAppend(outStr, '\\'); strAppend(outStr, '"'); break;
				case '\a': strAppend(outStr, '\\'); strAppend(outStr, 'a'); break;
				case '\b': strAppend(outStr, '\\'); strAppend(outStr, 'b'); break;
				case '\f': strAppend(outStr, '\\'); strAppend(outStr, 'f'); break;
				case '\n': strAppend(outStr, '\\'); strAppend(outStr, 'n'); break;
				case '\r': strAppend(outStr, '\\'); strAppend(outStr, 'r'); break;
				case '\t': strAppend(outStr, '\\'); strAppend(outStr, 't'); break;
				case '\v': strAppend(outStr, '\\'); strAppend(outStr, 'v'); break;
				default:
					if (c >= 0x20 && c <= 0x7E) strAppend(outStr, cast(char) c);
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
			strAppend(outStr, c);
			continue;
		}

		if (++i >= literal.length) {
			fail(err, "Trailing backslash in string", i);
			return outStr;
		}

		immutable esc = literal[i];
		switch (esc) {
			case '\\': strAppend(outStr, '\\'); break;
			case '\'': strAppend(outStr, '\''); break;
			case '"': strAppend(outStr, '"'); break;
			case 'a': strAppend(outStr, '\a'); break;
			case 'b': strAppend(outStr, '\b'); break;
			case 'f': strAppend(outStr, '\f'); break;
			case 'n': strAppend(outStr, '\n'); break;
			case 'r': strAppend(outStr, '\r'); break;
			case 't': strAppend(outStr, '\t'); break;
			case 'v': strAppend(outStr, '\v'); break;

			case 'x': { // \xh[h...] - one or more hex digits, low 8 bits kept
				if (i + 1 >= literal.length || !isHexDigit(literal[i + 1])) {
					fail(err, "Invalid \\x escape: no hex digit follows", i);
					return outStr;
				}
				uint v = 0;
				while (i + 1 < literal.length && isHexDigit(literal[i + 1]))
					v = (v << 4) | hexDigit(literal[++i], err);
				if (err.failed) return outStr;
				strAppend(outStr, cast(char) cast(ubyte) v);
				break;
			}

			case 'u': { // \uXXXX
				if (i + 4 >= literal.length) {
					fail(err, "Invalid \\u escape: insufficient characters", i);
					return outStr;
				}
				uint cp = 0;
				foreach (_; 0 .. 4)
					cp = (cp << 4) | hexDigit(literal[++i], err);
				if (err.failed) return outStr;
				appendUtf8(outStr, cp, err);
				if (err.failed) return outStr;
				break;
			}

			case 'U': { // \UXXXXXXXX
				if (i + 8 >= literal.length) {
					fail(err, "Invalid \\U escape: insufficient characters", i);
					return outStr;
				}
				uint cp = 0;
				foreach (_; 0 .. 8)
					cp = (cp << 4) | hexDigit(literal[++i], err);
				if (err.failed) return outStr;
				if (cp > 0x10FFFF) {
					fail(err, "Unicode code point out of range", i);
					return outStr;
				}
				appendUtf8(outStr, cp, err);
				if (err.failed) return outStr;
				break;
			}

			default:
				if (isOctal(esc)) {
					uint v = cast(uint)(esc - '0');
					foreach (_; 0 .. 2) {
						if (i + 1 < literal.length && isOctal(literal[i + 1]))
							v = (v << 3) | cast(uint)(literal[++i] - '0');
						else break;
					}
					strAppend(outStr, cast(char) cast(ubyte) v);
				} else {
					fail(err, "Invalid C++ escape sequence", i);
					return outStr;
				}
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
			strAppend(outStr, '"');
			strAppend(outStr, ' ');
			strAppend(outStr, '"');
		}
		needsSplice = false;

		if (c >= 0x20 && c <= 0x7E) {
			switch (c) {
				case '\\': strAppend(outStr, '\\'); strAppend(outStr, '\\'); break;
				case '"': strAppend(outStr, '\\'); strAppend(outStr, '"'); break;
				case '\'': strAppend(outStr, '\\'); strAppend(outStr, '\''); break;
				case '?': strAppend(outStr, '\\'); strAppend(outStr, '?'); break; // avoid trigraphs
				default: strAppend(outStr, cast(char) c); break;
			}
		} else {
			switch (c) {
				// `\0` is an octal escape, so a digit right behind it would be
				// absorbed into it the same way a hex digit is absorbed into
				// `\xhh`; splice the literal there too. (Every octal digit is
				// also a hex digit, so the `isHexDigit` test below covers it.)
				case '\0':
					strAppend(outStr, '\\');
					strAppend(outStr, '0');
					needsSplice = true;
					break;
				case '\a': strAppend(outStr, '\\'); strAppend(outStr, 'a'); break;
				case '\b': strAppend(outStr, '\\'); strAppend(outStr, 'b'); break;
				case '\f': strAppend(outStr, '\\'); strAppend(outStr, 'f'); break;
				case '\n': strAppend(outStr, '\\'); strAppend(outStr, 'n'); break;
				case '\r': strAppend(outStr, '\\'); strAppend(outStr, 'r'); break;
				case '\t': strAppend(outStr, '\\'); strAppend(outStr, 't'); break;
				case '\v': strAppend(outStr, '\\'); strAppend(outStr, 'v'); break;
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
	// needs to recognise the discard name must compare content.
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

unittest { // every simple Python escape decodes to the byte it names
	static immutable string[11] cases = [
		"\\\\", "\\'", "\\\"", "\\a", "\\b", "\\f", "\\n", "\\r", "\\t", "\\v", "\\\n",
	];
	static immutable string[11] expected = [
		"\\", "'", "\"", "\a", "\b", "\f", "\n", "\r", "\t", "\v", "", // trailing: line continuation
	];
	foreach (i, c; cases) {
		StringProcessingError err;
		auto decoded = unescapePythonString(c, err);
		scope(exit) strFree(decoded);
		assert(!err.failed);
		assert((decoded is null ? "" : strSlice(decoded)) == expected[i]);
	}
}

unittest { // ...and a plain character passes straight through
	StringProcessingError err;
	auto decoded = unescapePythonString("plain text", err);
	scope(exit) strFree(decoded);
	assert(!err.failed);
	assert(strSlice(decoded) == "plain text");
}

unittest { // \xhh, in both digit cases
	StringProcessingError err;
	auto decoded = unescapePythonString("\\x41\\xfF", err);
	scope(exit) strFree(decoded);
	assert(!err.failed);
	assert(strSlice(decoded) == "A\xff");
}

unittest { // octal escapes take up to three digits, and stop at a non-octal one
	StringProcessingError err;
	auto decoded = unescapePythonString("\\101\\78", err);
	scope(exit) strFree(decoded);
	assert(!err.failed);
	assert(strSlice(decoded) == "A\x078");
}

unittest { // \U reaches past the BMP, where appendUtf8 emits four bytes
	StringProcessingError err;
	auto decoded = unescapePythonString("\\U0001F600", err); // grinning face
	scope(exit) strFree(decoded);
	assert(!err.failed);
	assert(strSlice(decoded) == "\xf0\x9f\x98\x80");
}

unittest { // and \u the one-byte and two-byte cases
	StringProcessingError err;
	auto decoded = unescapePythonString("\\u0041\\u00e9", err);
	scope(exit) strFree(decoded);
	assert(!err.failed);
	assert(strSlice(decoded) == "A\xc3\xa9");
}

unittest { // every way a Python escape can fail reports through `err`
	static immutable string[7] bad = [
		"\\",          // trailing backslash
		"\\q",         // not an escape at all
		"\\x",         // \x with nothing behind it
		"\\xzz",       // ...or with non-hex digits
		"\\u00",       // \u truncated
		"\\U0000",     // \U truncated
		"\\UFFFFFFFF", // out of Unicode range
	];
	foreach (c; bad) {
		StringProcessingError err;
		auto decoded = unescapePythonString(c, err);
		scope(exit) strFree(decoded); // the partial result still has to be freed
		assert(err.failed);
		assert(err.message.length > 0);
	}
}

unittest { // a surrogate half is not a legal codepoint in UTF-8
	StringProcessingError err;
	auto decoded = unescapePythonString("\\ud800", err);
	scope(exit) strFree(decoded);
	assert(err.failed);
}

unittest { // `fail` keeps the *first* error rather than the last
	StringProcessingError err;
	fail(err, "first", 1);
	fail(err, "second", 2);
	assert(err.failed);
	assert(err.message == "first");
	assert(err.start == 1);
}

unittest { // appendUtf8 rejects anything above the Unicode maximum
	char* out_ = null;
	scope(exit) strFree(out_);
	StringProcessingError err;
	appendUtf8(out_, 0x110000, err);
	assert(err.failed);
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
	static immutable string[10] cases = [
		"\\", "'", "\"", "\a", "\b", "\f", "\n", "\r", "\t", "\v",
	];
	static immutable string[10] expected = [
		"\\\\", "\\'", "\\\"", "\\a", "\\b", "\\f", "\\n", "\\r", "\\t", "\\v",
	];
	foreach (i, c; cases) {
		auto escaped = escapePythonString(c);
		scope(exit) strFree(escaped);
		assert(strSlice(escaped) == expected[i]);
	}
}

unittest { // printable ASCII stays literal; anything else below 0x80 goes to \xhh
	auto printable = escapePythonString("Az09 ~");
	scope(exit) strFree(printable);
	assert(strSlice(printable) == "Az09 ~");

	static immutable char[1] control = [cast(char) 0x01];
	auto escaped = escapePythonString(control[0 .. 1]);
	scope(exit) strFree(escaped);
	assert(strSlice(escaped) == "\\x01");
}

unittest { // a codepoint past the BMP escapes as \U, not \u
	auto escaped = escapePythonString("\xf0\x9f\x98\x80"); // grinning face
	scope(exit) strFree(escaped);
	assert(strSlice(escaped) == "\\U0001f600");
}

unittest { // decodeUtf8 handles each sequence length, and truncation at each
	static immutable string[4] whole = ["A", "\xc3\xa9", "\xe2\x82\xac", "\xf0\x9f\x98\x80"];
	static immutable uint[4] expected = [0x41, 0xE9, 0x20AC, 0x1F600];
	foreach (n, s; whole) {
		size_t i = 0;
		assert(decodeUtf8(s, i) == expected[n]);
		assert(i == s.length);
	}

	// A lead byte with its continuation bytes cut off decodes as itself and
	// still advances, so the caller cannot loop forever or read past the end.
	foreach (s; whole[1 .. $]) {
		auto truncated = s[0 .. $ - 1];
		size_t i = 0;
		immutable cp = decodeUtf8(truncated, i);
		assert(i > 0);
		assert(cp == cast(ubyte) truncated[0] || i == truncated.length);
	}
}

unittest { // the C++ escaper names the same set, and hex-escapes the rest
	static immutable string[11] cases = [
		"\\", "\"", "'", "?", "\a", "\b", "\f", "\n", "\r", "\t", "\v",
	];
	static immutable string[11] expected = [
		"\\\\", "\\\"", "\\'", "\\?", "\\a", "\\b", "\\f", "\\n", "\\r", "\\t", "\\v",
	];
	foreach (i, c; cases) {
		auto escaped = escapeCppString(c);
		scope(exit) strFree(escaped);
		assert(strSlice(escaped) == expected[i]);
	}

	auto plain = escapeCppString("ok");
	scope(exit) strFree(plain);
	assert(strSlice(plain) == "ok");
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

unittest { // the C++ unescaper accepts everything the Python one does...
	StringProcessingError err;
	auto decoded = unescapeCppString(
		"\\\\\\'\\\"\\a\\b\\f\\n\\r\\t\\v\\x41\\u0041\\U00000041\\101\\78", err);
	scope(exit) strFree(decoded);
	assert(!err.failed);
	assert(strSlice(decoded) == "\\'\"\a\b\f\n\r\t\vAAAA\x078");
}

unittest { // ...its \x is greedy, keeping only the low byte...
	StringProcessingError err;
	auto decoded = unescapeCppString("\\x141", err);
	scope(exit) strFree(decoded);
	assert(!err.failed);
	assert(strSlice(decoded) == "\x41");
}

unittest { // ...and it reports the same failures
	static immutable string[6] bad = [
		"\\", "\\q", "\\x", "\\xz", "\\u00", "\\UFFFFFFFF",
	];
	foreach (c; bad) {
		StringProcessingError err;
		auto decoded = unescapeCppString(c, err);
		scope(exit) strFree(decoded);
		assert(err.failed);
	}
}

unittest { // a \u naming a surrogate fails inside appendUtf8, not before it
	StringProcessingError err;
	auto decoded = unescapeCppString("\\udc00", err);
	scope(exit) strFree(decoded);
	assert(err.failed);
}

unittest { // replaceAll rewrites every occurrence, and ignores an empty needle
	auto s = escapePythonString("a-b-c");
	scope(exit) strFree(s);
	replaceAll(s, "-", "+");
	assert(strSlice(s) == "a+b+c");

	replaceAll(s, "", "!"); // would loop forever if it were honoured
	assert(strSlice(s) == "a+b+c");
}

unittest { // a BMP codepoint above 0x7FF is three UTF-8 bytes
	StringProcessingError err;
	auto decoded = unescapePythonString("\\u20ac", err); // euro sign
	scope(exit) strFree(decoded);
	assert(!err.failed);
	assert(strSlice(decoded) == "\xe2\x82\xac");
}

unittest { // the C++ unescaper's \U needs all eight digits present
	StringProcessingError err;
	auto decoded = unescapeCppString("\\U0000", err);
	scope(exit) strFree(decoded);
	assert(err.failed);
}
