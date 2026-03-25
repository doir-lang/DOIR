#pragma once

#include "../module.hpp"
#include "../interface.hpp"
#include "../systems.hpp"
#include <stdexcept>

namespace doir::sema::validate {
	inline bool function_arity(ecrs::context& ctx, ecrs::entity_t subtree) {
		auto& mod = (doir::module&)ctx; // TODO: Verify cast
		if(!mod.has_component<doir::call>(subtree)) return true;

		auto decl = mod.get_component<doir::call>(subtree).related[0];
		auto ft = mod.get_component<doir::type_of>(decl).related[0];
		auto& call_inputs = mod.get_component<doir::function_inputs>(subtree);
		auto& decl_inputs = mod.get_component<doir::function_inputs>(ft);

		if(call_inputs.related.size() != decl_inputs.related.size()) {
			throw std::runtime_error("TODO: Function arity differs");
			return false;
		}
		return true;
	}
}
