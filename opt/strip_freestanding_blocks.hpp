#pragma once

#include "../interface.hpp"
#include "../module.hpp"
#include "../systems.hpp"

namespace doir::opt {
	inline bool strip_freestanding_blocks(ecrs::context& ctx, ecrs::entity_t subtree) {
		auto& mod = (doir::module&)ctx; // TODO: Verify cast
		if(mod.flags_set(subtree, doir::flags::Export)) return true;

		if(!mod.has_component<doir::block>(subtree)) return true;
		auto& block = mod.get_component<doir::block>(subtree);
		if(!block.is_freestanding(mod, subtree)) return true;

		auto parent = doir::find_parent(mod, subtree);
		if(parent == ecrs::invalid_entity) return true;

		auto& parent_related = mod.get_component<doir::block>(parent).related;
		parent_related.erase(std::remove(parent_related.begin(), parent_related.end(), subtree), parent_related.end());

		return true;
	}
}
