#include "compute_compiler_namespace.hpp"

#include "../module.hpp"
#include "../interface.hpp"
#include "../systems.hpp"
#include "opt/materialize_aliases.hpp"
#include "storage.hpp"

#include "../sema/lookup.hpp"
#include <algorithm>
#include <cstddef>
#include <functional>
#include <stdexcept>
#include <string>
#include <unordered_map>

namespace doir::opt {
	bool compute_base_type(doir::module& mod, ecrs::entity_t subtree, ecrs::entity_t function) {
		if(!mod.has_component<doir::function_inputs>(subtree)) {
			throw std::runtime_error("TODO: base_type expects two inputs");
			return false;
		}
		auto inputs = mod.get_component<doir::function_inputs>(subtree).related;
		if(inputs.size() != 2) {
			throw std::runtime_error("TODO: base_type expects two inputs");
			return false;
		}
		inputs = resolve_alias(mod, inputs);
		for(size_t i = 0; i < 2; ++i)
			if(!mod.has_component<doir::number>(inputs[i])){
				// TODO: It would probably be good to relax this constraint in the future
				throw std::runtime_error("TODO: base_type parameter "+std::to_string(i)+" must be a numeric constant");
				return false;
			}

		size_t size_bits = mod.get_component<doir::number>(inputs[0]).value;
		size_t align_bits = mod.get_component<doir::number>(inputs[0]).value;
		struct helper {
			std::size_t operator()(const std::pair<size_t, size_t>& p) const noexcept {
		        std::size_t h1 = std::hash<size_t>{}(p.first);
		        std::size_t h2 = std::hash<size_t>{}(p.second);
		        return h1 ^ (h2 << 1); // or use boost::hash_combine
		    }
		};
		static std::unordered_map<std::pair<size_t, size_t>, size_t, helper> unique_counter;
		size_t unique = unique_counter[{size_bits, align_bits}]++;

		mod.remove_component<doir::type_of>(subtree);
		mod.add_component<doir::print_as_call>(subtree).related[0] = function;
		mod.remove_component<doir::call>(subtree);
		// mod.remove_component<doir::function_inputs>(subtree);

		doir::block_builder::attach_type(mod, subtree);
		auto& type = mod.get_component<doir::type_definition>(subtree);
		type.size = size_bits;
		type.align = align_bits;
		type.unique = unique;

		return true;
	}

	bool compute_pointer(doir::module& mod, ecrs::entity_t subtree, ecrs::entity_t function) {
		if(!mod.has_component<doir::function_inputs>(subtree)) {
			throw std::runtime_error("TODO: pointer expects one input");
			return false;
		}
		auto inputs = mod.get_component<doir::function_inputs>(subtree).related;
		if(inputs.size() != 1) {
			throw std::runtime_error("TODO: pointer expects one input");
			return false;
		}
		inputs = resolve_alias(mod, inputs);
		if(!mod.has_component<doir::type_definition>(inputs[0])){
			throw std::runtime_error("TODO: base_type parameter 0 must be a type");
			return false;
		}

		mod.remove_component<doir::type_of>(subtree);
		mod.remove_component<doir::call>(subtree);
		mod.remove_component<doir::function_inputs>(subtree);

		doir::block_builder::attach_pointer(mod, subtree, inputs[0]);

		return true;
	}

	bool compute_bitwise_and(doir::module& mod, ecrs::entity_t subtree, ecrs::entity_t function) {
		if(inside_function(mod, subtree))
			return true;

		if(!mod.has_component<doir::function_inputs>(subtree)) {
			throw std::runtime_error("TODO: bitwise_and expects two inputs");
			return false;
		}
		auto inputs = mod.get_component<doir::function_inputs>(subtree).related;
		if(inputs.size() != 2) {
			throw std::runtime_error("TODO: bitwise_and expects two inputs");
			return false;
		}
		inputs = resolve_alias(mod, inputs);
		for(size_t i = 0; i < 2; ++i)
			if(!mod.has_component<doir::number>(inputs[i])){
				// TODO: It would probably be good to relax this constraint in the future
				throw std::runtime_error("TODO: bitwise_and parameter "+std::to_string(i)+" must be a numeric constant");
				return false;
			}

		size_t v = mod.get_component<doir::number>(inputs[0]).value;
		size_t mask = mod.get_component<doir::number>(inputs[1]).value;

		mod.add_component<doir::print_as_call>(subtree).related[0] = function;
		mod.remove_component<doir::call>(subtree);
		mod.add_component<doir::number>(subtree).value = v & mask;

		return true;
	}

	bool compute_shift_right(doir::module& mod, ecrs::entity_t subtree, ecrs::entity_t function) {
		if(inside_function(mod, subtree))
			return true;

		if(!mod.has_component<doir::function_inputs>(subtree)) {
			throw std::runtime_error("TODO: shift_right expects two inputs");
			return false;
		}
		auto inputs = mod.get_component<doir::function_inputs>(subtree).related;
		if(inputs.size() != 2) {
			throw std::runtime_error("TODO: shift_right expects two inputs");
			return false;
		}
		inputs = resolve_alias(mod, inputs);
		for(size_t i = 0; i < 2; ++i)
			if(!mod.has_component<doir::number>(inputs[i])){
				// TODO: It would probably be good to relax this constraint in the future
				throw std::runtime_error("TODO: shift_right parameter "+std::to_string(i)+" must be a numeric constant");
				return false;
			}

		size_t v = mod.get_component<doir::number>(inputs[0]).value;
		size_t shift = mod.get_component<doir::number>(inputs[1]).value;

		mod.add_component<doir::print_as_call>(subtree).related[0] = function;
		mod.remove_component<doir::call>(subtree);
		mod.add_component<doir::number>(subtree).value = v >> shift;

		return true;
	}

	bool compute_register_for(doir::module& mod, ecrs::entity_t subtree, ecrs::entity_t target, ecrs::entity_t function, bool force_register_values) {
		static ecrs::entity_t register_ = lookup::resolve(mod, "compiler.assembler.register", target);
		target = resolve_alias(mod, target);

		// TODO: Some sort of actual register allocation logic would be nice
		if(!mod.has_component<assigned_register>(target)) {
			std::cerr << "WARNING: Entity " << target << " doesn't have an associated reigster" << std::endl;
			if(force_register_values) mod.add_component<assigned_register>(target).reg = 0;
			else return true;
		}

		std::cout << target << " -> " << mod.get_component<assigned_register>(target).reg << std::endl;

		mod.remove_component<doir::type_of>(subtree);
		mod.add_component<doir::print_as_call>(subtree).related[0] = function;
		mod.remove_component<doir::call>(subtree);
		doir::block_builder::attach_number(mod, subtree, register_, mod.get_component<assigned_register>(target).reg);
		return true;
	}

	bool compute_compiler_namespace(ecrs::context& ctx, ecrs::entity_t subtree, bool force_register_values) {
		auto& mod = (doir::module&)ctx; // TODO: Verify cast
		if(!mod.has_component<doir::call>(subtree)) return true;

		static ecrs::entity_t pointer = lookup::resolve(mod, "compiler.pointer", subtree);
		static ecrs::entity_t base_type = lookup::resolve(mod, "compiler.base_type", subtree);
		static ecrs::entity_t bitwise_and = lookup::resolve(mod, "compiler.bitwise_and", subtree);
		static ecrs::entity_t shift_right = lookup::resolve(mod, "compiler.shift_right", subtree);
		static ecrs::entity_t debug_print = lookup::resolve(mod, "compiler.debug_print", subtree);
		static ecrs::entity_t assembler_register_for = lookup::resolve(mod, "compiler.assembler.register_for", subtree);
		static ecrs::entity_t assembler_return_register = lookup::resolve(mod, "compiler.assembler.return_register", subtree);
		static ecrs::entity_t assembler_yield_register = lookup::resolve(mod, "compiler.assembler.yield_register", subtree);

		auto function = mod.get_component<doir::call>(subtree).related[0];
		if(function == base_type)
			return compute_base_type(mod, subtree, base_type);

		else if(function == pointer)
			return compute_pointer(mod, subtree, pointer);

		else if(function == bitwise_and)
			return compute_bitwise_and(mod, subtree, bitwise_and);

		else if(function == shift_right)
			return compute_shift_right(mod, subtree, shift_right);

		else if(function == debug_print) {
			if(!mod.has_component<doir::function_inputs>(subtree)) {
				throw std::runtime_error("TODO: debug_print expects two inputs");
				return false;
			}
			auto& inputs = mod.get_component<doir::function_inputs>(subtree);
			if(inputs.related.size() != 2) {
				throw std::runtime_error("TODO: debug_print expects two inputs");
				return false;
			}

			doir::print(std::cout << subtree << " -> ", mod, inputs.related[1], true, true) << std::endl;

		} else if(function == assembler_register_for) {
			if(!mod.has_component<doir::function_inputs>(subtree)) {
				throw std::runtime_error("TODO: register_for expects two inputs");
				return false;
			}
			auto& inputs = mod.get_component<doir::function_inputs>(subtree);
			if(inputs.related.size() != 2) {
				throw std::runtime_error("TODO: register_for expects two inputs");
				return false;
			}

			return compute_register_for(mod, subtree, inputs.related[1], assembler_register_for, force_register_values);

		} else if(function == assembler_yield_register) {
			auto parent = doir::find_parent(mod, subtree);
			if(mod.has_component<doir::function_return_type>(parent)) {
				throw std::runtime_error("TODO: Used yield_register in function... did you mean to use return_register?");
				return false;
			}

			return compute_register_for(mod, subtree, parent, assembler_yield_register, force_register_values);

		} else if(function == assembler_return_register) {
			// throw std::runtime_error("TODO: Non-inlined functions aren't yet supported... can't get return register");
		}

		return true;
	}
}
