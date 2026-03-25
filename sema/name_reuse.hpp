#pragma once

#include "../module.hpp"
#include "../interface.hpp"
#include "../systems.hpp"
#include "storage.hpp"
#include <algorithm>
#include <stdexcept>
#include <vector>

namespace doir::sema::validate {
	inline bool name_reuse(ecrs::context& ctx, ecrs::entity_t subtree) {
		auto& mod = (doir::module&)ctx; // TODO: Verify cast
		if(!mod.has_component<doir::block>(subtree)) return true;

		auto& block = mod.get_component<doir::block>(subtree);
		std::vector<std::pair<doir::interned_string, ecrs::entity_t>> names; names.reserve(block.related.size());
		for(auto e: block.related)
			if(mod.has_component<doir::name>(e))
				names.emplace_back(mod.get_component<doir::name>(e), e);
		if(names.empty()) return true;

		std::unordered_map<doir::interned_string, std::vector<ecrs::entity_t>> frequency;
	    for (auto [name, e] : names)
	        frequency[name].push_back(e);

		for(auto& [name, entities]: frequency)
			if(entities.size() > 1) {
				throw std::runtime_error("TODO: " + std::string(name) + " reused");
			}

		return true;
	}
}
