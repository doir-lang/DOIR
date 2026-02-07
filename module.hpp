#pragma once

#include "libecrs/context.hpp"
#include <string_view>

namespace peg {
	struct parser;
}

namespace doir {
	struct module : public ecrs::context {
		std::string_view source;
		std::optional<std::string_view> working_file = {};

		bool parse(peg::parser& parser, std::string_view source, std::string_view path = "generated.doir");
		bool parse_file(peg::parser& parser, std::string_view path);
	};
}
