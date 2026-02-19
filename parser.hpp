#pragma once

#include "interface.hpp"

#include <peglib.h>

namespace doir {

	peg::parser initialize_parser(fp::raii::dynarray<doir::block_builder>& blocks, doir::string_interner& interner, bool guarantee_source_location = false);

}
