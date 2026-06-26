#pragma once

#include "../module.hpp"
#include "../interface.hpp"
#include "../systems.hpp"
#include "diagnostics.hpp"
#include "sema/lookup.hpp"
#include <stdexcept>

namespace doir::sema::validate {
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
			auto location = doir::find_source_location(mod, subtree);
			auto& diag = push_diagnostic(doir::diagnostic_type::InvalidFunctionCall, location, mod.source, mod.working_file.value_or(invalid_file_name));
			diagnose::diagnostic::annotation annotation;
			annotation.message = "Number of function parameters " + std::string(doir::ansi::info) + std::to_string(call_inputs.related.size()) + diagnose::ansi::reset
				+ " differs from expected number " + std::string(doir::ansi::info) + std::to_string(decl_inputs.related.size()) + diagnose::ansi::reset; 

				auto range = parse_parameter_range(mod.source.substr(location.start_byte, location.end_byte - location.start_byte), call_inputs.related.size() - 1);
				if(range) 
					location.start_byte += (range->start + range->end) / 2;
			annotation.position = location.start(mod.source);
			diag.annotations.push_back(annotation);
			return false;
		}
		return true;
	}
}
