#pragma once

#include "../module.hpp"
#include "../interface.hpp"
#include "../systems.hpp"
#include "storage.hpp"

namespace doir::opt {
	inline ecrs::entity_t resolve_alias(ecrs::context ctx, ecrs::entity_t alias) {
		auto& mod = (doir::module&)ctx; // TODO: Verify cast
		while(mod.has_component<doir::alias>(alias))
			alias = mod.get_component<doir::alias>(alias).related[0];
		return alias;
	}

	inline std::vector<ecrs::entity_t> resolve_alias(ecrs::context ctx, std::vector<ecrs::entity_t> aliases) {
		for(auto& alias: aliases)
			alias = resolve_alias(ctx, alias);
		return aliases;
	}

	inline bool materialize_aliases(ecrs::context& ctx, ecrs::entity_t subtree, ecrs::entity_t root = current_canonicalize_root) {
		auto& mod = (doir::module&)ctx; // TODO: Verify cast
		if(!mod.has_component<doir::alias>(subtree)) return true;
		if(!mod.has_component<doir::parent>(subtree)) return true;
		if(root == current_canonicalize_root) root = canonicalize::new_root;

		auto& alias = mod.get_component<doir::alias>(subtree);
		if(alias.file) return true; // Can't materialize aliases to other files

		auto parent = mod.get_component<doir::parent>(subtree).related[0];
		auto& block = mod.get_component<doir::block>(parent);
		auto it = std::find(block.related.begin(), block.related.end(), subtree);

		mod.substitute_entities(root, {{subtree, resolve_alias(mod, alias.related[0])}});
		*it = subtree; // Undo the substitution in the block itself

		return true;
	}
}
