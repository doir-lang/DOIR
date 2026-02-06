#pragma once
#include "string_helpers.hpp"

#include <cassert>
#include <string>
#include <string_view>

namespace doir {
	struct source_location {
		struct pair {
			size_t line = 1, column = 1;

			size_t to_byte(std::string_view source) {
			    size_t line = 1;
			    size_t column = 1;

			    for (size_t i = 0; i < source.size(); ++i) {
			        if (line == this->line && column == this->column)
			            return i;

			        if (source[i] == '\n') {
			            ++line;
			            column = 1;
			        } else
			            ++column;
			    }

			    // Allow pointing one-past-the-end (e.g. EOF)
			    if (line == this->line && column == this->column)
			        return source.size();

			    assert(false && "pair out of range for source");
			    return source.size();
			}
		};

		struct detailed {
			std::string_view file;
			pair start, end;

			source_location to_bytes(std::string_view source) {
				return {file, start.to_byte(source), end.to_byte(source)};
			}
		};

		std::string_view file;
		size_t start_byte, end_byte;

	 	pair find_pair(std::string_view source, size_t target_byte) const {
			assert(target_byte <= source.size());

		    auto lines = split(source, '\n');
		    pair out = {1, 1};
		    for (size_t i = 0; i < target_byte; ++i) {
		        ++out.column;

		        // If we stepped past the end of the current line, wrap
		        if (out.column > lines[out.line - 1].size() + 1) {
		            out.column = 1;
		            ++out.line;
		        }
			}

		    return out;
		}

		pair start(std::string_view source) const { return find_pair(source, start_byte); }
		size_t start_line(std::string_view source) const { return start(source).line; }
		size_t start_column(std::string_view source) const { return start(source).column; }

		pair end(std::string_view source) const { return find_pair(source, end_byte); }
		size_t end_line(std::string_view source) const { return end(source).line; }
		size_t end_column(std::string_view source) const { return end(source).column; }

		detailed to_detailed(std::string_view source) const {
			return {file, start(source), end(source)};
		}
	};
}
