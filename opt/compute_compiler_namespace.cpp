#include "compute_compiler_namespace.hpp"

#include "../module.hpp"
#include "../interface.hpp"
#include "../systems.hpp"
#include "materialize_aliases.hpp"
#include "storage.hpp"

#include "../sema/lookup.hpp"
#include "../sema/error_helper.hpp"
#include <algorithm>
#include <cstddef>
#include <functional>
#include <stdexcept>
#include <string>
#include <unordered_map>

namespace doir::opt {
	bool compute_base_type(doir::module& mod, ecrs::entity_t subtree, ecrs::entity_t function, ecrs::entity_t comptime_base_type) {
		if(!mod.has_component<doir::function_inputs>(subtree)) {
			EXPECTS_X_INPUTS("base_type", "two");
			return false;
		}
		auto inputs = mod.get_component<doir::function_inputs>(subtree).related;
		if(inputs.size() != 2) {
			EXPECTS_X_INPUTS("base_type", "two");
			return false;
		}
		inputs = doir::alias::resolve(mod, inputs);
		bool valid = true;
		for(size_t i = 0; i < 2; ++i)
			if(!mod.has_component<doir::number>(inputs[i])){
				// TODO: It would probably be good to relax this constraint in the future
				PARAMETER_ERROR("base_type", i, " must evaluate to a numeric constant");
				valid = false;
			}
		if(!valid) return false;

		size_t size_bits = mod.get_component<doir::number>(inputs[0]).value;
		size_t align_bits = mod.get_component<doir::number>(inputs[1]).value;
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
		if(function == comptime_base_type)
			mod.get_or_add_component<doir::flags>(subtree).as_underlying() |= doir::flags::AlwaysComptime;

		return true;
	}

	bool compute_pointer(doir::module& mod, ecrs::entity_t subtree, ecrs::entity_t function) {
		if(!mod.has_component<doir::function_inputs>(subtree)) {
			EXPECTS_X_INPUTS("pointer", "one");
			return false;
		}
		auto inputs = mod.get_component<doir::function_inputs>(subtree).related;
		if(inputs.size() != 1) {
			EXPECTS_X_INPUTS("pointer", "one");
			return false;
		}
		inputs = doir::alias::resolve(mod, inputs);
		if(!mod.has_component<doir::type_definition>(inputs[0])){
			PARAMETER_ERROR("pointer", 0, " must evaluate to a type");
			return false;
		}

		mod.remove_component<doir::type_of>(subtree);
		mod.remove_component<doir::call>(subtree);
		mod.remove_component<doir::function_inputs>(subtree);

		doir::block_builder::attach_pointer(mod, subtree, inputs[0]);

		return true;
	}

	bool compute_always_inline(doir::module& mod, ecrs::entity_t subtree, ecrs::entity_t function) {
		if(!mod.has_component<doir::function_inputs>(subtree)) {
			EXPECTS_X_INPUTS("always_inline", "one");
			return false;
		}
		auto inputs = mod.get_component<doir::function_inputs>(subtree).related;
		if(inputs.size() != 1) {
			EXPECTS_X_INPUTS("always_inline", "one");
			return false;
		}
		inputs = doir::alias::resolve(mod, inputs);
		if(!mod.has_component<doir::type_definition>(inputs[0])){
			PARAMETER_ERROR("always_inline", 0, " must evaluate to a type");
			return false;
		}

		auto type = inputs[0];
		mod.get_or_add_component<doir::flags>(type).as_underlying() |= doir::flags::Inline;

		mod.remove_component<doir::type_of>(subtree);
		mod.add_component<doir::print_as_call>(subtree).related[0] = function;
		mod.remove_component<doir::call>(subtree);
		mod.remove_component<doir::function_inputs>(subtree);

		doir::block_builder::attach_alias(mod, subtree, type);
		return true;
	}

	bool compute_always_comptime(doir::module& mod, ecrs::entity_t subtree, ecrs::entity_t function) {
		if(!mod.has_component<doir::function_inputs>(subtree)) {
			EXPECTS_X_INPUTS("always_comptime", "one");
			return false;
		}
		auto inputs = mod.get_component<doir::function_inputs>(subtree).related;
		if(inputs.size() != 1) {
			EXPECTS_X_INPUTS("always_comptime", "one");
			return false;
		}
		inputs = doir::alias::resolve(mod, inputs);
		if(!mod.has_component<doir::type_definition>(inputs[0])){
			PARAMETER_ERROR("always_comptime", 0, " must evaluate to a type");
			return false;
		}

		auto type = inputs[0];
		mod.get_or_add_component<doir::flags>(type).as_underlying() |= doir::flags::AlwaysComptime;

		mod.remove_component<doir::type_of>(subtree);
		mod.add_component<doir::print_as_call>(subtree).related[0] = function;
		mod.remove_component<doir::call>(subtree);
		mod.remove_component<doir::function_inputs>(subtree);

		doir::block_builder::attach_alias(mod, subtree, type);
		return true;
	}

	bool compute_bitwise_and(doir::module& mod, ecrs::entity_t subtree, ecrs::entity_t function) {
		if(find_function_inside_of(mod, subtree))
			return true;

		if(!mod.has_component<doir::function_inputs>(subtree)) {
			EXPECTS_X_INPUTS("bitwise_and", "one");
			return false;
		}
		auto inputs = mod.get_component<doir::function_inputs>(subtree).related;
		if(inputs.size() != 2) {
			EXPECTS_X_INPUTS("bitwise_and", "one");
			return false;
		}
		inputs = doir::alias::resolve(mod, inputs);
		bool valid = true;
		for(size_t i = 0; i < 2; ++i)
			if(!mod.has_component<doir::number>(inputs[i])){
				// TODO: It would probably be good to relax this constraint in the future
				PARAMETER_ERROR("bitwise_and", i, " must evaluate to a numeric constant");
				valid = false;
			}
		if(!valid) return false;

		size_t v = mod.get_component<doir::number>(inputs[0]).value;
		size_t mask = mod.get_component<doir::number>(inputs[1]).value;

		mod.add_component<doir::print_as_call>(subtree).related[0] = function;
		mod.remove_component<doir::call>(subtree);
		mod.add_component<doir::number>(subtree).value = v & mask;

		return true;
	}

	bool compute_shift_right(doir::module& mod, ecrs::entity_t subtree, ecrs::entity_t function) {
		if(find_function_inside_of(mod, subtree))
			return true;

		if(!mod.has_component<doir::function_inputs>(subtree)) {
			EXPECTS_X_INPUTS("shift_right", "two");
			return false;
		}
		auto inputs = mod.get_component<doir::function_inputs>(subtree).related;
		if(inputs.size() != 2) {
			EXPECTS_X_INPUTS("shift_right", "two");
			return false;
		}
		inputs = doir::alias::resolve(mod, inputs);
		bool valid = true;
		for(size_t i = 0; i < 2; ++i)
			if(!mod.has_component<doir::number>(inputs[i])){
				// TODO: It would probably be good to relax this constraint in the future
				PARAMETER_ERROR("shift_right", i, " must evaluate to a numeric constant");
				valid = false;
			}
		if(!valid) return false;

		size_t v = mod.get_component<doir::number>(inputs[0]).value;
		size_t shift = mod.get_component<doir::number>(inputs[1]).value;

		mod.add_component<doir::print_as_call>(subtree).related[0] = function;
		mod.remove_component<doir::call>(subtree);
		mod.add_component<doir::number>(subtree).value = v >> shift;

		return true;
	}

	bool compute_register_for(doir::module& mod, ecrs::entity_t subtree, ecrs::entity_t target, ecrs::entity_t function, bool force_register_values) {
		static ecrs::entity_t register_ = lookup::resolve(mod, "compiler.assembler.register", 1);
		target = doir::alias::resolve(mod, target);
		if(mod.has_component<doir::function_parameter>(target)) 
			return true;

		mod.remove_component<doir::type_of>(subtree);
		mod.add_component<doir::print_as_call>(subtree).related[0] = function;
		mod.remove_component<doir::call>(subtree);
		auto r = mod.has_component<assigned_register>(target) ? mod.get_component<assigned_register>(target).reg : 0;
		doir::block_builder::attach_number(mod, subtree, register_, r);
		return true;
	}

	bool compute_compiler_namespace(ecrs::context& ctx, ecrs::entity_t subtree, bool force_register_values) {
		auto& mod = (doir::module&)ctx; // TODO: Verify cast
		if(!mod.has_component<doir::call>(subtree)) return true;

		static ecrs::entity_t pointer = lookup::resolve(mod, "compiler.pointer", 1);
		static ecrs::entity_t base_type = lookup::resolve(mod, "compiler.base_type", 1);
		static ecrs::entity_t comptime_base_type = lookup::resolve(mod, "compiler.comptime_base_type", 1);
		static ecrs::entity_t bitwise_and = lookup::resolve(mod, "compiler.bitwise_and", 1);
		static ecrs::entity_t shift_right = lookup::resolve(mod, "compiler.shift_right", 1);
		static ecrs::entity_t debug_print = lookup::resolve(mod, "compiler.debug_print", 1);
		static ecrs::entity_t always_inline = lookup::resolve(mod, "compiler.always_inline", 1);
		static ecrs::entity_t always_comptime = lookup::resolve(mod, "compiler.always_comptime", 1);
		static ecrs::entity_t assembler_register_for = lookup::resolve(mod, "compiler.assembler.register_for", 1);
		static ecrs::entity_t assembler_return_register = lookup::resolve(mod, "compiler.assembler.return_register", 1);
		static ecrs::entity_t assembler_yield_register = lookup::resolve(mod, "compiler.assembler.yield_register", 1);

		static ecrs::entity_t compiler_current_entity = doir::lookup::resolve(mod, "compiler.current_entity", 1, true);
		mod.get_component<doir::number>(compiler_current_entity).value = subtree;

		auto function = mod.get_component<doir::call>(subtree).related[0];
		if(function == base_type || function == comptime_base_type)
			return compute_base_type(mod, subtree, function, comptime_base_type);

		if(function == always_inline)
			return compute_always_inline(mod, subtree, always_inline);

		if(function == always_comptime)
			return compute_always_comptime(mod, subtree, always_comptime);

		else if(function == pointer)
			return compute_pointer(mod, subtree, pointer);

		else if(function == bitwise_and)
			return compute_bitwise_and(mod, subtree, bitwise_and);

		else if(function == shift_right)
			return compute_shift_right(mod, subtree, shift_right);

		else if(function == debug_print) {
			if(!mod.has_component<doir::function_inputs>(subtree)) {
				EXPECTS_X_INPUTS("debug_print", "two");
				return false;
			}
			auto& inputs = mod.get_component<doir::function_inputs>(subtree);
			if(inputs.related.size() != 2) {
				EXPECTS_X_INPUTS("debug_print", "two");
				return false;
			}

			doir::print(std::cout << subtree << " -> ", mod, inputs.related[1], true, true) << std::endl;

		} else if(function == assembler_register_for) {
			if(!mod.has_component<doir::function_inputs>(subtree)) {
				EXPECTS_X_INPUTS("register_for", "two");
				return false;
			}
			auto& inputs = mod.get_component<doir::function_inputs>(subtree);
			if(inputs.related.size() != 2) {
				EXPECTS_X_INPUTS("register_for", "two");
				return false;
			}

			return compute_register_for(mod, subtree, inputs.related[1], assembler_register_for, force_register_values);

		} else if(function == assembler_yield_register) {
			auto parent = doir::find_parent(mod, subtree);
			if(mod.has_component<doir::function_return_type>(parent)) {
				auto& diag = push_diagnostic(doir::diagnostic_type::InvalidFunctionCall, doir::find_detailed_source_location(mod, subtree), mod.source, mod.working_file.value_or(invalid_file_name));
				diagnose::diagnostic::annotation annotation;
				annotation.message = "Used " + std::string(doir::ansi::function) + "yield_register" + diagnose::ansi::reset + " in function... did you mean to use " 
					+ doir::ansi::function + "return_register" + diagnose::ansi::reset + "?";
				annotation.position = diag.location.start;
				diag.annotations.push_back(annotation);
				return false;
			}

			return compute_register_for(mod, subtree, parent, assembler_yield_register, force_register_values);

		} else if(function == assembler_return_register) {
			auto func = find_function_inside_of(mod, subtree);
			if(func == ecrs::invalid_entity) {
				auto& diag = push_diagnostic(doir::diagnostic_type::InvalidFunctionCall, doir::find_detailed_source_location(mod, subtree), mod.source, mod.working_file.value_or(invalid_file_name));
				diagnose::diagnostic::annotation annotation;
				annotation.message = "Used " + std::string(doir::ansi::function) + "return_register" + diagnose::ansi::reset + " outside of a function";
				annotation.position = diag.location.start;
				diag.annotations.push_back(annotation);
				return false;
			}

 			// throw std::runtime_error("TODO: Non-inlined functions aren't yet supported... can't get return register");
		}

		return true;
	}
}
