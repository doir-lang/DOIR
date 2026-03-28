#pragma once

#include "diagnose/string_helpers.hpp"
#include "../interface.hpp"
#include "../module.hpp"
#include "../string_helpers.hpp"

namespace doir {
	ecrs::entity_t find_parent(const doir::module& mod, ecrs::entity_t e);
	bool inside_function(const doir::module& mod, ecrs::entity_t subtree);

	namespace lookup {
		ecrs::entity_t resolve(doir::module& mod, doir::interned_string lookup, ecrs::entity_t search_start);
		ecrs::entity_t resolve(doir::module& mod, doir::lookup::lookup& lookup, ecrs::entity_t search_start);
	}

	namespace sema {
		bool resolve_lookups(ecrs::context& mod, ecrs::entity_t subtree);
		namespace validate {
			bool lookups_resolved(ecrs::context& mod, ecrs::entity_t subtree);
		}
	}
}
