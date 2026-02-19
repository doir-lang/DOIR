#pragma once

#include "libecrs/context.hpp"
#include <string_view>

namespace peg {
	struct parser;
}

namespace doir {
	struct module : public ecrs::context {
		fp::string::view source;
		std::optional<fp::string::view> working_file = {};

		bool parse(peg::parser& parser, fp::string::view source, fp::string::view path = "generated.doir");
		bool parse_file(peg::parser& parser, fp::string::view path);
	};
}
