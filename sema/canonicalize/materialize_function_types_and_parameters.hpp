#pragma once

#include "../module.hpp"
#include "../interface.hpp"
#include "../systems.hpp"
#include "sema/lookup.hpp"
#include "../function_arity.hpp"
#include "storage.hpp"
#include <stdexcept>

namespace doir::canonicalize {

	inline bool materialize_function_types_and_parameters(ecrs::context& ctx, ecrs::entity_t subtree) {
		auto& mod = (doir::module&)ctx; // TODO: Verify cast
		if( !(mod.has_component<doir::type_of>(subtree) || mod.has_component<doir::lookup::type_of>(subtree)) ) return true;

		doir::lookup::lookup lookup = mod.has_component<doir::type_of>(subtree)
			? doir::lookup::lookup(mod.get_component<doir::type_of>(subtree).related[0])
			: doir::lookup::lookup(mod.get_component<doir::lookup::type_of>(subtree));
		if(!lookup.resolved()) return true;
		auto ft = sema::validate::resolve_type_modifications(mod, lookup.entity());
		if(ft == ecrs::invalid_entity) return true;
		if( !(mod.has_component<doir::function_return_type>(ft) || mod.has_component<doir::lookup::function_return_type>(ft)) ) return true;

		if( !(mod.has_component<doir::function_return_type>(subtree) || mod.has_component<doir::lookup::function_return_type>(subtree)) ) {
			if(mod.has_component<doir::function_return_type>(ft))
				mod.add_component<doir::function_return_type>(subtree) = mod.get_component<doir::function_return_type>(ft);
			if(mod.has_component<doir::lookup::function_return_type>(ft))
				mod.add_component<doir::lookup::function_return_type>(subtree) = mod.get_component<doir::lookup::function_return_type>(ft);
		}

		if(!mod.has_component<doir::block>(subtree)) return true;
		// auto call_inputs = mod.has_component<doir::function_inputs>(subtree)
		// 	? doir::lookup::function_inputs::to_lookup(mod.get_component<doir::function_inputs>(subtree))
		// 	: mod.get_component<doir::lookup::function_inputs>(subtree);
		// auto& call_inputs = mod.get_component<doir::function_inputs>(subtree);
		// auto& decl_inputs = mod.get_component<doir::function_inputs>(ft);
		auto decl_inputs = mod.has_component<doir::function_inputs>(ft)
			? doir::lookup::function_inputs::to_lookup(mod.get_component<doir::function_inputs>(ft))
			: mod.get_component<doir::lookup::function_inputs>(ft);
		if(decl_inputs.associated_parameters(mod, mod.get_component<doir::block>(subtree)).empty()) {
			doir::function_builder builder{subtree, &mod};
			builder.push_parameters(ft);
		}

		return true;
	}
}
