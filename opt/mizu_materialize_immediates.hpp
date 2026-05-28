#pragma once

#include "../module.hpp"
#include "../interface.hpp"
#include "../systems.hpp"

#include "../sema/lookup.hpp"
#include "../sema/error_helper.hpp"
#include "materialize_aliases.hpp"
#include "compute_compiler_namespace.hpp"
#include <string>
#include <vector>

namespace doir::opt {
	extern size_t next_register;

	namespace mizu {
		inline bool materialize_immediates(ecrs::context& ctx, ecrs::entity_t subtree) {
			auto& mod = (doir::module&)ctx; // TODO: Verify cast
			if(!mod.has_component<doir::call>(subtree)) return true;

			static ecrs::entity_t u64 = lookup::resolve(mod, "u64", subtree);
			static ecrs::entity_t byte = lookup::resolve(mod, "compiler.byte", subtree);
			static ecrs::entity_t emit = lookup::resolve(mod, "compiler.emit", subtree);
			static ecrs::entity_t indicate_yield = lookup::resolve(mod, "compiler.indicate_yield", subtree);
			static ecrs::entity_t load_immediate = lookup::resolve(mod, "load_immediate", subtree);
			static ecrs::entity_t load_immediate_op = lookup::resolve(mod, "load_immediate_op", subtree);
			static ecrs::entity_t load_upper_immediate = lookup::resolve(mod, "load_upper_immediate", subtree);
			static ecrs::entity_t load_upper_immediate_op = lookup::resolve(mod, "load_upper_immediate_op", subtree);

			auto function = mod.get_component<doir::call>(subtree).related[0];
			if( !(function == load_immediate || function == load_upper_immediate) ) return true;

			if(!mod.has_component<doir::function_inputs>(subtree)) {
				EXPECTS_X_INPUTS("load_immediate", "two");
				return false;
			}
			auto inputs = mod.get_component<doir::function_inputs>(subtree).related;
			if(inputs.size() != 2) {
				EXPECTS_X_INPUTS("load_immediate", "two");
				return false;
			}
			inputs = resolve_alias(mod, inputs);
			if(!mod.has_component<doir::number>(inputs[1])){
				// TODO: It would probably be good to relax this constraint in the future
				PARAMETER_ERROR("load_immediate", 0, " must evaluate to a numeric constant");
				return false;
			}

			auto target = inputs[1];
			uint32_t value = mod.get_component<doir::number>(target).value;

			auto type = mod.get_component<doir::type_of>(subtree).related[0];
			mod.remove_component<doir::type_of>(subtree);
			mod.remove_component<doir::call>(subtree);
			auto builder = doir::block_builder::attach_subblock(mod, subtree, type);
			{
				std::vector<ecrs::entity_t> inputs = {u64};
				ecrs::entity_t c;
				if(function == load_immediate)
					c = builder.push_call("_", u64, load_immediate_op, inputs);
				else c = builder.push_call("_", u64, load_upper_immediate_op, inputs);
				mod.get_or_add_component<doir::flags>(c).as_underlying() = doir::flags::Inline;

				// TODO: Some sort of actual register allocation logic would be nice
				if(!mod.has_component<assigned_register>(target)) {
					NO_ASSOCIATED_REGISTER();
					return false;
				}
				auto r = mod.get_component<assigned_register>(target).reg;
				mod.get_or_add_component<assigned_register>(subtree).reg = r;

				// std::cout << target << " -> " << r << std::endl;
				// std::cout << subtree << " -> " << r << std::endl;

				uint8_t low = r & 0xFF;
	   			inputs = {builder.push_number(mod.interner.intern("low"), byte, low)};
		  		builder.push_call("_", byte, emit, inputs);
				uint8_t high = (r >> 8) & 0xFF;
				inputs = {builder.push_number(mod.interner.intern("high"), byte, high)};
				builder.push_call("_", byte, emit, inputs);

				auto bytes = fp::view<uint32_t>::from_variable(value).byte_view();
			 	for(size_t i = 0; i < bytes.size(); ++i) {
					inputs = {builder.push_number(mod.interner.intern("%" + std::to_string(i)), byte, (int)bytes[i])};
					builder.push_call("_", byte, emit, inputs);
				}

				inputs = {builder.push_number(mod.interner.intern("zero"), byte, 0)};
				for(size_t i = 0; i < 2; ++i) // Need to fill in another uint16_t
					builder.push_call("_", byte, emit, inputs);

				inputs = {u64};
				builder.push_call("_", u64, indicate_yield, inputs);
			}
			builder.end();
			return true;
		}
	}
}
