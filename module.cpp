#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#define FP_OSTREAM_SUPPORT

#include "module.hpp"
#include "file_manager.hpp"
#include "peglib.h"

namespace doir {
	bool module::parse(peg::parser& parser, fp::string::view source, fp::string::view path /*= "generated.doir"*/) {
		auto backup = working_file;
		working_file = path;
		this->source = source;
		auto out = parser.parse(source.to_std(), path.data());
		working_file = backup;
		return out;
	}

	bool module::parse_file(peg::parser& parser, fp::string::view path) {
		return parse(parser, doir::file_manager::singleton().get_file_string(path.to_std()), path);
	}
}
