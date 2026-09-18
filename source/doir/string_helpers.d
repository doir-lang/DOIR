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

/// libfp's own `append` asserts the string is already allocated, so this
/// null-safe one-character append stands in for it throughout.
private void strAppend(ref char* s, char c) @trusted @nogc nothrow {
	concatenateSlice(s, (&c)[0 .. 1]);
}

@nogc nothrow:


/// True if `small` points into `big`'s buffer (the C++ `doir::contains`).
bool containsView(const(char)[] big, const(char)[] small) @trusted {
	return small.ptr < big.ptr + big.length && small.ptr + small.length <= big.ptr + big.length;
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

	size_t length() const { return view.length; }
	bool empty() const { return view.length == 0; }
	char opIndex(size_t i) const { return view[i]; }

	/// The `_` name, which `push_common` treats as "don't attach a name".
	static InternedString wildcard() { return InternedString("_"); }
}

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

/// Looks `s` up without interning it. `found` is false if it isn't present.
InternedString findInterned(ref StringInterner self, const(char)[] s, out bool found) @trusted {
	auto probe = InternEntry(s);
	if (auto hit = fp.hashtable.find(self.table, probe)) {
		found = true;
		return InternedString(hit.text);
	}
	found = false;
	return InternedString(null);
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

/// Minimal UTF-8 decoder (assumes valid UTF-8 input).
private uint decodeUtf8(const(char)[] s, ref size_t i) @trusted {
	immutable c = cast(ubyte) s[i];

	if (c < 0x80) {
		return cast(uint) s[i++];
	} else if ((c >> 5) == 0x6) {
		immutable cp = ((c & 0x1F) << 6) | (cast(ubyte) s[i + 1] & 0x3F);
		i += 2;
		return cp;
	} else if ((c >> 4) == 0xE) {
		immutable cp = ((c & 0x0F) << 12)
			| ((cast(ubyte) s[i + 1] & 0x3F) << 6)
			| (cast(ubyte) s[i + 2] & 0x3F);
		i += 3;
		return cp;
	} else {
		immutable cp = ((c & 0x07) << 18)
			| ((cast(ubyte) s[i + 1] & 0x3F) << 12)
			| ((cast(ubyte) s[i + 2] & 0x3F) << 6)
			| (cast(ubyte) s[i + 3] & 0x3F);
		i += 4;
		return cp;
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
				case '\0': strAppend(outStr, '\\'); strAppend(outStr, '0'); break;
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
	assert(empty.length == 0);

	bool found;
	auto looked = findInterned(interner, "", found);
	assert(found);
	assert(looked.length == 0);
}

unittest { // find reports nothing for strings that were never interned
	auto interner = createInterner();
	scope(exit) free(interner);
	intern(interner, "hello");

	bool found;
	findInterned(interner, "does_not_exist", found);
	assert(!found);
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
	assert(underscore.view == InternedString.wildcard.view);
	assert(underscore != InternedString.wildcard);
}

unittest { // an interned string compares to a plain slice by content
	auto interner = createInterner();
	scope(exit) free(interner);
	auto interned = intern(interner, "hello");
	assert(interned == "hello");
}

// NOTE: the C++ suite also asserted `string_interner(0)` throws
// `std::invalid_argument`. `-betterC` has no exceptions; `createInterner`
// asserts instead, which cannot be caught and so cannot be tested here.
