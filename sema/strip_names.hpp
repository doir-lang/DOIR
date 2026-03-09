#pragma once

#include "../interface.hpp"
#include "../module.hpp"
#include "util.hpp"

namespace doir::sema {
	inline bool strip_names(ecrs::context& mod, ecrs::entity_t subtree) {
		if(mod.has_component<doir::flags>(subtree) && mod.get_component<doir::flags>(subtree).export_set()) return true;

		if(mod.has_component<doir::name>(subtree))
			mod.remove_component<doir::name>(subtree);
		if(mod.has_component<doir::function_parameter_names>(subtree))
			mod.remove_component<doir::function_parameter_names>(subtree);

		return true;
	}

	// DOIR_MAKE_SORTED_WALKER(strip_names, false)
}
