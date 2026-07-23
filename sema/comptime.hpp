#pragma once

#include "../module.hpp"
#include "../interface.hpp"
#include "sema/error_helper.hpp"
#include "storage.hpp"
#include "systems.hpp"
#include "lookup.hpp"
#include <stdexcept>
#include <string>

namespace doir::sema {

	// NOTE: This system is fixed point aware
	// This system bubbles comptime awareness down through the
	inline bool bubble_comptime(ecrs::context& ctx, ecrs::entity_t subtree) {
		auto& mod = (doir::module&)ctx; // TODO: Verify cast
		if(mod.has_component<doir::call>(subtree)) {
			if(!mod.has_component<doir::function_inputs>(subtree)) return true;
			if(mod.flags_set(subtree, doir::flags::NoComptime)) return true;

			auto& inputs = mod.get_component<doir::function_inputs>(subtree);
			bool comptime = true;
			for(auto e: inputs.related)
				if(!mod.flags_set(e, doir::flags::Comptime)) {
					if(mod.has_component<type_definition>(e)) continue; // All types are compile time known

					comptime = false;
					break;
				}

			auto function = mod.get_component<doir::call>(subtree).related[0];
			auto ft = doir::alias::resolve(mod, mod.get_component<doir::type_of>(function).related[0]);
			auto comptime_function = mod.flags_set(ft, doir::flags::Comptime);

			bool is_comptime = mod.flags_set(subtree, doir::flags::Comptime);

			if(comptime || comptime_function) {
				mod.get_or_add_component<doir::flags>(subtree).as_underlying() |= doir::flags::Comptime;
				if(!is_comptime) system::fixed_point_changed() = true;
			} else if(is_comptime) {
				mod.get_component<doir::flags>(subtree).as_underlying() &= ~doir::flags::Comptime;
				system::fixed_point_changed() = true;
			}

		} else if(mod.has_component<doir::type_of>(subtree)) {
			if(mod.flags_set(subtree, doir::flags::NoComptime)) return true;

			auto type = doir::type_definition::base_type(mod, mod.get_component<doir::type_of>(subtree).related[0]);

			static ecrs::entity_t comptime_base_type = doir::lookup::resolve(mod, "compiler.comptime_base_type", 1);
			bool always_comptime = false;
			if(mod.has_component<doir::call>(type) && mod.get_component<doir::call>(type).related[0] == comptime_base_type)
				always_comptime = true;
			else if(!mod.has_component<doir::type_definition>(type)) return true;
			else always_comptime = mod.flags_set(type, doir::flags::AlwaysComptime);

			bool is_comptime = mod.flags_set(subtree, doir::flags::Comptime);
			if(!is_comptime && always_comptime) {
				mod.get_or_add_component<doir::flags>(subtree).as_underlying() |= doir::flags::Comptime;
				system::fixed_point_changed() = true;
			}
		}

		return true;
	}

	namespace validate {
		inline bool comptime(ecrs::context& ctx, ecrs::entity_t subtree) {
			auto& mod = (doir::module&)ctx; // TODO: Verify cast
			if(!mod.has_component<doir::call>(subtree)) return true;
			if(!mod.has_component<doir::function_inputs>(subtree)) return true;

			auto& inputs = mod.get_component<doir::function_inputs>(subtree);
			size_t non_comptime_input = -1;
			for(size_t i = 0; i < inputs.related.size(); ++i) {
				auto e = inputs.related[i];
				if(!mod.flags_set(e, doir::flags::Comptime)) {
					if(mod.has_component<type_definition>(e)) continue; // All types are compile time known

					non_comptime_input = i;
					break;
				}
			}

			if(non_comptime_input != -1 && mod.flags_set(subtree, doir::flags::Comptime)) {
				static ecrs::entity_t register_for = lookup::resolve(mod, "compiler.assembler.register_for", 1);
				if(mod.get_component<doir::call>(subtree).related[0] == register_for && non_comptime_input == 1) return true; // register_for is allowed to take a non comptime value for its second parameter

				auto name = mod.has_component<doir::name>(subtree) ? std::string(mod.get_component<doir::name>(subtree)) : "%" + std::to_string(subtree);
				PARAMETER_ERROR(name, non_comptime_input, " is not compile time known despite being provided to a compile time call.");
				return false;
			}
			return true;
		}
	}
}
