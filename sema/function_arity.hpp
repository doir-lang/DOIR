#pragma once

#include "../module.hpp"
#include "../interface.hpp"
#include "../systems.hpp"
#include "sema/lookup.hpp"
#include <stdexcept>

namespace doir::sema::validate {
	inline ecrs::entity_t resolve_type_modifications(const doir::module& mod, ecrs::entity_t type) {
		while(mod.has_component<doir::call>(type) || mod.has_component<doir::lookup::call>(type)) {
			doir::lookup::lookup call = mod.has_component<doir::call>(type)
				? doir::lookup::lookup(mod.get_component<doir::call>(type).related[0])
				: doir::lookup::lookup(mod.get_component<doir::lookup::call>(type));
			if(!call.resolved()) return type;

			auto func = call.entity();
			// If this is a type modifier then we keep resolving
			if(!block_builder::get_type_modifiers(mod, type).contains(func))
				return type;

			auto inputs = mod.has_component<doir::function_inputs>(type)
				? doir::lookup::function_inputs::to_lookup(mod.get_component<doir::function_inputs>(type))
				: mod.get_component<doir::lookup::function_inputs>(type);
			if(!inputs[0].resolved()) return type;
			type = inputs[0].entity();
		}
		return type;
	}

	inline bool function_arity(ecrs::context& ctx, ecrs::entity_t subtree) {
		auto& mod = (doir::module&)ctx; // TODO: Verify cast
		if(!mod.has_component<doir::call>(subtree)) return true;

		auto decl = mod.get_component<doir::call>(subtree).related[0];
		auto ft = resolve_type_modifications(mod, mod.get_component<doir::type_of>(decl).related[0]);
		// if(!mod.has_component<doir::function_return_type>(decl))
		// 	mod.add_component<doir::function_return_type>(decl) = mod.get_component<doir::function_return_type>(ft);

		auto& call_inputs = mod.get_component<doir::function_inputs>(subtree);
		auto& decl_inputs = mod.get_component<doir::function_inputs>(ft);
		// if(mod.has_component<doir::block>(decl) && decl_inputs.associated_parameters(mod, mod.get_component<doir::block>(decl)).empty()) {
		// 	doir::function_builder builder{decl, &mod};
		// 	builder.push_parameters(sema::validate::resolve_type_modifications(mod, ft));
		// }

		if(call_inputs.related.size() != decl_inputs.related.size()) {
			throw std::runtime_error("TODO: Function arity differs");
			return false;
		}
		return true;
	}
}
