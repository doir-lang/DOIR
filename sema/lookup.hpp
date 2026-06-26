#pragma once

#include "diagnose/string_helpers.hpp"
#include "../interface.hpp"
#include "../module.hpp"
#include "../string_helpers.hpp"

namespace doir {
	namespace sema {
		bool resolve_lookups(ecrs::context& mod, ecrs::entity_t subtree, bool types_only);
		namespace validate {
			bool lookups_resolved(ecrs::context& mod, ecrs::entity_t subtree);
		}
	}
}
