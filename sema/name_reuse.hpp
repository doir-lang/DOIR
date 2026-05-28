#pragma once

#include "../module.hpp"
#include "../interface.hpp"
#include "../systems.hpp"
#include "diagnostics.hpp"
#include "storage.hpp"
#include <algorithm>
#include <stdexcept>
#include <vector>

namespace doir::sema::validate {
	inline bool name_reuse(ecrs::context& ctx, ecrs::entity_t subtree) {
		auto& mod = (doir::module&)ctx; // TODO: Verify cast
		if(!mod.has_component<doir::block>(subtree)) return true;

		auto& block = mod.get_component<doir::block>(subtree);
		std::vector<std::pair<doir::interned_string, ecrs::entity_t>> names; names.reserve(block.related.size());
		for(auto e: block.related)
			if(mod.has_component<doir::name>(e))
				names.emplace_back(mod.get_component<doir::name>(e), e);
		if(names.empty()) return true;

		std::unordered_map<doir::interned_string, std::vector<ecrs::entity_t>> frequency;
	    for (auto [name, e] : names)
	        frequency[name].push_back(e);

		bool valid = true;
		for(auto& [name, entities]: frequency)
			if(entities.size() > 1) {
				auto location = doir::find_source_location(mod, entities[0]);
				auto& diag = push_diagnostic(doir::diagnostic_type::FailedToResolveLookup, location, mod.source, mod.working_file.value_or(invalid_file_name));
				diagnose::diagnostic::annotation annotation;
				annotation.message = doir::ansi::info + std::string(name) + diagnose::ansi::reset + " appears to have been redefined";
				auto start = mod.source.substr(location.start_byte, location.end_byte - location.start_byte).find(name);
				if(start != std::string::npos) 
					location.start_byte += start;
				annotation.position = location.start(mod.source);
				diag.annotations.push_back(annotation);

				// Also point to its reuses
				for(size_t i = 1; i < entities.size(); ++i) {
					diagnose::diagnostic::annotation annotation;
					annotation.message = doir::ansi::info + std::string(name) + diagnose::ansi::reset + " also defined here";
					auto location = doir::find_source_location(mod, entities[1]);
					auto start = mod.source.substr(location.start_byte, location.end_byte - location.start_byte).find(name);
					if(start != std::string::npos) 
						location.start_byte += start;
					annotation.position = location.start(mod.source);
					diag.annotations.push_back(annotation); // TODO: What happens if the uses are in different files?
				}
				
				valid = false;
			}

		return valid;
	}
}
