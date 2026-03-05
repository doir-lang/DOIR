#pragma once

#include "diagnose/string_helpers.hpp"
#include "../interface.hpp"
#include "../module.hpp"
#include "../string_helpers.hpp"

namespace doir {
	namespace lookup {
		ecrs::entity_t resolve(doir::module& mod, doir::interned_string lookup, ecrs::entity_t search_start);
		ecrs::entity_t resolve(doir::module& mod, doir::lookup::lookup& lookup, ecrs::entity_t search_start);
	}

	namespace sema {
		bool resolve_lookups(doir::module& mod, ecrs::entity_t subtree);
	}
}
