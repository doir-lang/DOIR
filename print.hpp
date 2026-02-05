#pragma once

#include "interface.hpp"
#include "module.hpp"
#include <ostream>

namespace doir {
	std::ostream& print(std::ostream& out, const module& mod, ecrs::entity_t root, bool pretty = true, bool debug = false);
}
