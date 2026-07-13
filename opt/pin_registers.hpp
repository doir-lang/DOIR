#pragma once

#include "../module.hpp"
#include "../interface.hpp"
#include "../systems.hpp"

#include "../sema/lookup.hpp"
#include "../sema/error_helper.hpp"
#include "materialize_aliases.hpp"
#include "compute_compiler_namespace.hpp"
#include <stdexcept>

namespace doir::opt {
	inline bool pin_registers(ecrs::context& ctx, ecrs::entity_t subtree) {
		auto& mod = (doir::module&)ctx; // TODO: Verify cast
		if(!mod.has_component<doir::call>(subtree)) return true;
		
		static ecrs::entity_t pin_register = lookup::resolve(mod, "compiler.assembler.pin_register", 1);
		auto function = mod.get_component<doir::call>(subtree).related[0];
		if(function != pin_register) return true;

		auto inputs = mod.get_component<doir::function_inputs>(subtree).related;
		if(inputs.size() != 3) {
			EXPECTS_X_INPUTS("pin_register", "three");
			return true;
		}
		inputs = doir::alias::resolve(mod, inputs);

		if(!mod.has_component<doir::number>(inputs[2])) {
			PARAMETER_ERROR("pin_register", 2, " must be be a numeric constant");
			return true;
		}

		auto target = inputs[1];
		size_t r = mod.get_component<doir::number>(inputs[2]).value;

		mod.get_or_add_component<doir::opt::assigned_register>(target).reg = r;
		// std::cout << target << " -> " << r << std::endl;

		return true;
	}
}
