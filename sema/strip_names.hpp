#pragma once

#include "../interface.hpp"
#include "../module.hpp"
#include "../systems.hpp"

namespace doir::sema {
	inline bool strip_names(ecrs::context& ctx, ecrs::entity_t subtree) {
		auto& mod = (doir::module&)ctx; // TODO: Verify cast
		if(mod.flags_set(subtree, doir::flags::Export)) return true;

		if(mod.has_component<doir::name>(subtree))
			mod.remove_component<doir::name>(subtree);
		if(mod.has_component<doir::function_parameter_names>(subtree))
			mod.remove_component<doir::function_parameter_names>(subtree);

		return true;
	}

	// DOIR_MAKE_SORTED_WALKER(strip_names, false)
}
