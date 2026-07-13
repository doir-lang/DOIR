#pragma once

// #include "peglib.h"
#include "../module.hpp"
#include "../interface.hpp"
#include "../systems.hpp"
#include "../sema/error_helper.hpp"

#include <filesystem>
#include "../file_manager.hpp"

namespace doir::canonicalize {
	inline bool process_early_include(ecrs::context& ctx, ecrs::entity_t subtree, peg::parser& parser, std::vector<doir::block_builder>& builders) {
		auto& mod = (doir::module&)ctx; // TODO: Verify cast
		if( !(mod.has_component<doir::call>(subtree) || mod.has_component<doir::lookup::call>(subtree)) ) return true;

		static ecrs::entity_t include = lookup::resolve(mod, "early_include", 1);
		static ecrs::entity_t pointer_sized = lookup::resolve(mod, "compiler.pointer_sized", 1);
		
		bool is_include = false;
		if(mod.has_component<doir::call>(subtree))
			is_include = mod.get_component<doir::call>(subtree).related[0] == include;
		else if(mod.has_component<doir::lookup::call>(subtree)) {
			auto& lookup = mod.get_component<doir::lookup::call>(subtree);
			if(lookup.resolved()) is_include = lookup.resolved() == include;
			else is_include = std::string_view(lookup.name()) == "early_include";
		}
		if(!is_include) return true;

		auto block = doir::find_parent(mod, subtree);
		if(block == ecrs::invalid_entity) return true; // TODO: Should this be an error?
		if(!mod.has_component<doir::block>(block)) return true; // TODO: Should this be an error?

		if(!mod.has_component<doir::function_inputs>(subtree) && !mod.has_component<doir::lookup::function_inputs>(subtree)) {
			EXPECTS_X_INPUTS("early_include", "one");
			return false;
		}
		auto inputs = mod.has_component<doir::function_inputs>(subtree)
			? doir::lookup::function_inputs::to_lookup(mod.get_component<doir::function_inputs>(subtree))
			: mod.get_component<doir::lookup::function_inputs>(subtree);
		if(inputs.size() != 1) {
			EXPECTS_X_INPUTS("early_include", "one");
			return false;
		}
		ecrs::entity_t input;
		if(inputs[0].resolved()) input = inputs[0].resolved();
		else input = doir::lookup::resolve(mod, inputs[0].name(), subtree);
		input = doir::alias::resolve(mod, input);
		if(input == ecrs::invalid_entity) {
			EXPECTS_X_INPUTS("early_include", "one");
			return false;
		}
		if(!mod.has_component<doir::string>(input)){
			// TODO: It would probably be good to relax this constraint in the future
			PARAMETER_ERROR("early_include", 0, " must evaluate to a string constant");
			return false;
		}
		std::filesystem::path path = std::string_view(mod.get_component<doir::string>(input).value);
		path = std::filesystem::canonical(std::filesystem::absolute(path));

		builders.emplace_back(block_builder::create(mod));
		mod.parse_file(parser, mod.interner->intern(path.string()));
		auto blockE = builders.back().block;
		builders.pop_back();
		if(doir::diagnostics().has_errors()) return false;

		auto& parent = mod.get_component<doir::block>(block);
		auto& child = mod.get_component<doir::block>(blockE);
		child.inline_into(mod, block, parent.offset_of(subtree) + 1);

		// Replace the call with number of bytes in the file
		if(mod.has_component<doir::call>(subtree)) {
			mod.remove_component<doir::call>(subtree);
			mod.remove_component<doir::function_inputs>(subtree);
			mod.remove_component<doir::type_of>(subtree);	
		} else {
			mod.remove_component<doir::lookup::call>(subtree);
			mod.remove_component<doir::lookup::function_inputs>(subtree);
			mod.remove_component<doir::lookup::type_of>(subtree);
		}
		block_builder::attach_number(mod, subtree, pointer_sized, doir::file_manager::singleton().get_file_string(path).size());
		return true;
	}
}