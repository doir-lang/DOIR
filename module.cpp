#define NOMINMAX
#define WIN32_LEAN_AND_MEAN

#include "module.hpp"
#include "file_manager.hpp"
#include "peglib.h"

namespace doir {
	bool module::parse(peg::parser& parser, std::string_view source, std::string_view path /*= "generated.doir"*/) {
		auto backup = working_file;
		working_file = path;
		this->source = source;
		auto out = parser.parse(source, path.data());
		working_file = backup;
		return out;
	}

	bool module::parse_file(peg::parser& parser, std::string_view path) {
		return parse(parser, doir::file_manager::singleton().get_file_string(path), path);
	}
}
