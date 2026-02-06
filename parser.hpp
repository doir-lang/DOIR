#pragma once

#include "interface.hpp"

#include <peglib.h>

namespace doir {

	peg::parser initialize_parser(std::vector<doir::block_builder>& blocks, doir::string_interner& interner, bool garuntee_source_location = false);

}
