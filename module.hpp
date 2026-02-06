#pragma once

#include "libecrs/context.hpp"
#include <string_view>

namespace peg {
	struct parser;
}

namespace doir {
	struct module : public ecrs::context {
		std::string_view source;

		bool parse(peg::parser& parser, std::string_view path = "");
	};
}
