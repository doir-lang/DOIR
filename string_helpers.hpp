#pragma once

#include <cstddef>
#include <cstring>
#include <memory>
#include <optional>
#include <vector>
#include <string>
#include <string_view>
#include <unordered_set>
#include <stdexcept>
#include <cstdint>
#include <algorithm>

namespace doir {
	inline static bool contains(std::string_view big, std::string_view small) {
		return small.data() < big.data() + big.size() && small.data() + small.size() <= big.data() + big.size();
	}

	struct interned_string: public std::string_view {
		using std::string_view::string_view;
		using std::string_view::operator=;
		interned_string() = default;
		explicit interned_string(std::string_view sv) : std::string_view(sv) {}
		interned_string(const interned_string&) = default;
		interned_string(interned_string&&) = default;
		interned_string& operator=(const interned_string&) = default;
		interned_string& operator=(interned_string&&) = default;

		bool operator==(const interned_string& o) {
			return data() == o.data();
		}
		bool operator!=(const interned_string& o) {
			return data() != o.data();
		}
	};

	struct string_interner {
		explicit string_interner(size_t block_size = 4096) : block_size(block_size), offset(0) {
			if (block_size == 0)
				throw std::invalid_argument("block_size must be positive");
			add_block();
		}

		// Non-copyable but movable
		string_interner(const string_interner&) = delete;
		string_interner& operator=(const string_interner&) = delete;
		string_interner(string_interner&&) noexcept = default;
		string_interner& operator=(string_interner&&) noexcept = default;

		interned_string intern(std::string_view s) {
			auto it = table.find(s);
			if (it != table.end())
				return interned_string{*it};

			const char* p = allocate(s);
			interned_string interned{p, s.size()};
			table.emplace(interned);
			return interned;
		}

		std::optional<interned_string> find(std::string_view s) const {
			auto it = table.find(s);
			if (it != table.end())
				return interned_string{*it};
			return {};
		}

		size_t size() const noexcept { return table.size(); }

		size_t memory_used() const noexcept {
			size_t total = 0;
			for (size_t i = 0; i < blocks.size() - 1; ++i) {
				total += block_size;
			}
			total += offset; // Current block usage
			return total;
		}

	protected:
		const char* allocate(std::string_view s) {
			size_t n = s.size() + 1; // +1 for null terminator

			if (offset + n > block_size) {
				add_block((std::max)(block_size, n));
			}

			char* dst = blocks.back().get() + offset;
			std::memcpy(dst, s.data(), s.size());
			dst[s.size()] = '\0';
			offset += n;
			return dst;
		}

		void add_block(size_t size = 0) {
			size = size ? size : block_size;
			blocks.emplace_back(std::make_unique<char[]>(size));
			offset = 0;
		}

		size_t block_size;
		size_t offset;
		std::vector<std::unique_ptr<char[]>> blocks;
		std::unordered_set<std::string_view> table;
	};

	inline std::string& replace_all(std::string& haystack, std::string_view needle, std::string_view replacement) {
		if (needle.empty())
			return haystack; // avoid infinite loop

		std::size_t pos = 0;
		while ((pos = haystack.find(needle, pos)) != std::string::npos) {
			haystack.replace(pos, needle.length(), replacement);
			pos += replacement.length(); // move past the replacement
		}

		return haystack;
	}

	namespace detail {
		inline void append_utf8(std::string& out, uint32_t cp) {
			// Check for invalid code points
			if (cp > 0x10FFFF)
				throw std::runtime_error("Unicode code point out of range");

			// UTF-16 surrogate pairs (0xD800-0xDFFF) are invalid in UTF-8
			if (cp >= 0xD800 && cp <= 0xDFFF)
				throw std::runtime_error("Invalid Unicode code point (surrogate range)");

			if (cp <= 0x7F) {
				out.push_back(cp);
			} else if (cp <= 0x7FF) {
				out.push_back(static_cast<uint8_t>(0xC0 | (cp >> 6)));
				out.push_back(static_cast<uint8_t>(0x80 | (cp & 0x3F)));
			} else if (cp <= 0xFFFF) {
				out.push_back(static_cast<uint8_t>(0xE0 | (cp >> 12)));
				out.push_back(static_cast<uint8_t>(0x80 | ((cp >> 6) & 0x3F)));
				out.push_back(static_cast<uint8_t>(0x80 | (cp & 0x3F)));
			} else {
				out.push_back(static_cast<uint8_t>(0xF0 | (cp >> 18)));
				out.push_back(static_cast<uint8_t>(0x80 | ((cp >> 12) & 0x3F)));
				out.push_back(static_cast<uint8_t>(0x80 | ((cp >> 6) & 0x3F)));
				out.push_back(static_cast<uint8_t>(0x80 | (cp & 0x3F)));
			}
		}

		constexpr uint32_t hex_digit(char c) {
			if ('0' <= c && c <= '9') return c - '0';
			if ('a' <= c && c <= 'f') return c - 'a' + 10;
			if ('A' <= c && c <= 'F') return c - 'A' + 10;
			throw std::runtime_error("invalid hex digit");
		}

		constexpr bool is_octal(char c) noexcept {
			return c >= '0' && c <= '7';
		}

		inline void append_hex_escape(std::string& out, uint8_t c) {
			static const char* hex = "0123456789abcdef";
			out += "\\x";
			out += hex[(c >> 4) & 0xF];
			out += hex[c & 0xF];
		}

		inline void append_unicode_escape(std::string& out, uint32_t cp) {
			static const char* hex = "0123456789abcdef";

			if (cp <= 0xFFFF) {
				out += "\\u";
				for (int shift = 12; shift >= 0; shift -= 4)
					out += hex[(cp >> shift) & 0xF];
			} else {
				out += "\\U";
				for (int shift = 28; shift >= 0; shift -= 4)
					out += hex[(cp >> shift) & 0xF];
			}
		}

		// Minimal UTF-8 decoder (assumes valid UTF-8 input)
		inline uint32_t decode_utf8(std::string_view s, size_t& i) {
			unsigned char c = static_cast<unsigned char>(s[i]);

			if (c < 0x80) {
				return s[i++];
			} else if ((c >> 5) == 0x6) {
				uint32_t cp = ((c & 0x1F) << 6) |
							(static_cast<unsigned char>(s[i + 1]) & 0x3F);
				i += 2;
				return cp;
			} else if ((c >> 4) == 0xE) {
				uint32_t cp = ((c & 0x0F) << 12) |
							((static_cast<unsigned char>(s[i + 1]) & 0x3F) << 6) |
							(static_cast<unsigned char>(s[i + 2]) & 0x3F);
				i += 3;
				return cp;
			} else {
				uint32_t cp = ((c & 0x07) << 18) |
							((static_cast<unsigned char>(s[i + 1]) & 0x3F) << 12) |
							((static_cast<unsigned char>(s[i + 2]) & 0x3F) << 6) |
							(static_cast<unsigned char>(s[i + 3]) & 0x3F);
				i += 4;
				return cp;
			}
		}
	}

	inline std::string unescape_python_string(std::string_view literal) {
		std::string out;
		out.reserve(literal.size()); // Pre-allocate to reduce reallocations

		for (size_t i = 0; i < literal.size(); ++i) {
			char c = literal[i];

			if (c != '\\') {
				out.push_back(c);
				continue;
			}

			if (++i >= literal.size())
				throw std::runtime_error("trailing backslash in string");

			char esc = literal[i];

			switch (esc) {
			case '\n': break; // line continuation
			case '\\': out.push_back('\\'); break;
			case '\'': out.push_back('\''); break;
			case '"':  out.push_back('"');  break;
			case 'a':  out.push_back('\a'); break;
			case 'b':  out.push_back('\b'); break;
			case 'f':  out.push_back('\f'); break;
			case 'n':  out.push_back('\n'); break;
			case 'r':  out.push_back('\r'); break;
			case 't':  out.push_back('\t'); break;
			case 'v':  out.push_back('\v'); break;

			case 'x': { // \xhh
				if (i + 2 >= literal.size())
					throw std::runtime_error("invalid \\x escape: insufficient characters");

				uint32_t hi = detail::hex_digit(literal[++i]);
				uint32_t v  = (hi << 4) | detail::hex_digit(literal[++i]);
				out.push_back(static_cast<char>(v));
				break;
			}

			case 'u': { // \uXXXX
				if (i + 4 >= literal.size())
					throw std::runtime_error("invalid \\u escape: insufficient characters");

				uint32_t cp = 0;
				for (int k = 0; k < 4; ++k)
					cp = (cp << 4) | detail::hex_digit(literal[++i]);

				detail::append_utf8(out, cp);
				break;
			}

			case 'U': { // \UXXXXXXXX
				if (i + 8 >= literal.size())
					throw std::runtime_error("invalid \\U escape: insufficient characters");

				uint32_t cp = 0;
				for (int k = 0; k < 8; ++k)
					cp = (cp << 4) | detail::hex_digit(literal[++i]);

				if (cp > 0x10FFFF)
					throw std::runtime_error("Unicode code point out of range");

				detail::append_utf8(out, cp);
				break;
			}

			default:
				if (detail::is_octal(esc)) {
					// \0 – \777 (up to 3 digits)
					uint32_t v = esc - '0';
					for (int k = 0; k < 2; ++k)
						if (i + 1 < literal.size() && detail::is_octal(literal[i + 1]))
							v = (v << 3) | (literal[++i] - '0');
						else break;
					out.push_back(static_cast<char>(v));
				} else throw std::runtime_error(std::string("invalid escape sequence: \\") + esc);
			}
		}

		return out;
	}

	inline std::string escape_python_string(std::string_view input) {
		std::string out;
		out.reserve(input.size() * 2);

		for (size_t i = 0; i < input.size();) {
			unsigned char c = static_cast<unsigned char>(input[i]);

			// ASCII fast path
			if (c < 0x80) {
				++i;

				switch (c) {
				case '\\': out += "\\\\"; break;
				case '\'': out += "\\\'"; break;
				case '"':  out += "\\\""; break;

				case '\a': out += "\\a"; break;
				case '\b': out += "\\b"; break;
				case '\f': out += "\\f"; break;
				case '\n': out += "\\n"; break;
				case '\r': out += "\\r"; break;
				case '\t': out += "\\t"; break;
				case '\v': out += "\\v"; break;

				default:
					if (c >= 0x20 && c <= 0x7E) {
						out.push_back(static_cast<char>(c));
					} else {
						detail::append_hex_escape(out, c);
					}
				}
			} else {
				// Decode UTF-8 → codepoint
				uint32_t cp = detail::decode_utf8(input, i);

				// Encode as \u or \U
				detail::append_unicode_escape(out, cp);
			}
		}

		return out;
	}

	inline std::string unescape_cpp_string(std::string_view literal) {
		std::string out;
		out.reserve(literal.size());

		for (size_t i = 0; i < literal.size(); ++i) {
			char c = literal[i];

			if (c != '\\') {
				out.push_back(c);
				continue;
			}

			if (++i >= literal.size())
				throw std::runtime_error("trailing backslash in string");

			char esc = literal[i];

			switch (esc) {
			case '\\': out.push_back('\\'); break;
			case '\'': out.push_back('\''); break;
			case '"':  out.push_back('"');  break;
			// case '?':  out.push_back('?');  break; // trigraph prevention
			case 'a':  out.push_back('\a'); break;
			case 'b':  out.push_back('\b'); break;
			case 'f':  out.push_back('\f'); break;
			case 'n':  out.push_back('\n'); break;
			case 'r':  out.push_back('\r'); break;
			case 't':  out.push_back('\t'); break;
			case 'v':  out.push_back('\v'); break;

			case 'x': { // \xh[h…] — one or more hex digits; we take all and keep the low 8 bits
				if (i + 1 >= literal.size() || !std::isxdigit(static_cast<unsigned char>(literal[i + 1])))
					throw std::runtime_error("invalid \\x escape: no hex digit follows");

				uint32_t v = 0;
				while (i + 1 < literal.size() && std::isxdigit(static_cast<unsigned char>(literal[i + 1])))
					v = (v << 4) | detail::hex_digit(literal[++i]);

				out.push_back(static_cast<char>(static_cast<uint8_t>(v)));
				break;
			}

			case 'u': { // \uXXXX — exactly 4 hex digits, encoded as UTF-8
				if (i + 4 >= literal.size())
					throw std::runtime_error("invalid \\u escape: insufficient characters");

				uint32_t cp = 0;
				for (int k = 0; k < 4; ++k)
					cp = (cp << 4) | detail::hex_digit(literal[++i]);

				detail::append_utf8(out, cp);
				break;
			}

			case 'U': { // \UXXXXXXXX — exactly 8 hex digits, encoded as UTF-8
				if (i + 8 >= literal.size())
					throw std::runtime_error("invalid \\U escape: insufficient characters");

				uint32_t cp = 0;
				for (int k = 0; k < 8; ++k)
					cp = (cp << 4) | detail::hex_digit(literal[++i]);

				if (cp > 0x10FFFF)
					throw std::runtime_error("Unicode code point out of range");

				detail::append_utf8(out, cp);
				break;
			}

			default:
				if (detail::is_octal(esc)) {
					// \o, \oo, \ooo — 1 to 3 octal digits
					uint32_t v = static_cast<uint32_t>(esc - '0');
					for (int k = 0; k < 2; ++k) {
						if (i + 1 < literal.size() && detail::is_octal(literal[i + 1]))
							v = (v << 3) | static_cast<uint32_t>(literal[++i] - '0');
						else break;
					}
					out.push_back(static_cast<char>(static_cast<uint8_t>(v)));
				} else {
					throw std::runtime_error(std::string("invalid C++ escape sequence: \\") + esc);
				}
			}
		}

		return out;
	}

	inline std::string escape_cpp_string(std::string_view input) {
		std::string out;
		out.reserve(input.size() * 2);

		bool needs_splice = false; // set when last emission was \xhh

		for (size_t i = 0; i < input.size(); ++i) {
			unsigned char c = static_cast<unsigned char>(input[i]);

			// Close and reopen the literal to prevent the next hex digit from
			// being absorbed into the preceding \xhh escape.
			if (needs_splice && std::isxdigit(c))
				out += "\" \"";
			needs_splice = false;

			if (c >= 0x20 && c <= 0x7E) {
				switch (c) {
				case '\\': out += "\\\\"; break;
				case '"':  out += "\\\""; break;
				case '\'': out += "\\'";  break;
				case '?':  out += "\\?";  break; // avoid trigraph sequences
				default:   out.push_back(static_cast<char>(c)); break;
				}
			} else {
				switch (c) {
				case '\0': out += "\\0";  break;
				case '\a': out += "\\a";  break;
				case '\b': out += "\\b";  break;
				case '\f': out += "\\f";  break;
				case '\n': out += "\\n";  break;
				case '\r': out += "\\r";  break;
				case '\t': out += "\\t";  break;
				case '\v': out += "\\v";  break;
				default:
					detail::append_hex_escape(out, c);
					needs_splice = true;
					break;
				}
			}
		}

		return out;
	}

}

namespace std {
	template<>
	struct hash<doir::interned_string> : public hash<string_view> {};
}
