#pragma once

#include <cstddef>
#include <cstring>
#include <memory>
#include <vector>
#include <string>
#include <string_view>
#include <unordered_set>
#include <stdexcept>
#include <cstdint>
#include <algorithm>

namespace doir {

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

	inline std::vector<std::string_view> split(std::string_view str, char delimiter) {
	    std::vector<std::string_view> result;

	    size_t start = 0;
	    while (true) {
	        size_t pos = str.find(delimiter, start);
	        if (pos == std::string_view::npos) {
	            result.emplace_back(str.substr(start));
	            break;
	        }
	        result.emplace_back(str.substr(start, pos - start));
	        start = pos + 1;
	    }

	    return result;
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

				uint32_t v = (detail::hex_digit(literal[++i]) << 4) | detail::hex_digit(literal[++i]);
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

}

namespace std {
	template<>
	struct hash<doir::interned_string> : public hash<string_view> {};
}
