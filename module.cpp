#include "module.hpp"
#include "peglib.h"

namespace doir {
	bool module::parse(peg::parser& parser, std::string_view path /*= ""*/) {
		return parser.parse(source, path.data());
	}
}
