#pragma once

#include "libecrs/context.hpp"
#include <string_view>

namespace doir {
	struct module : public ecrs::context {
		std::string_view source;
	};
}
