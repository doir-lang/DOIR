#define NOMINMAX
#define WIN32_LEAN_AND_MEAN

#include "module.hpp"
#include "file_manager.hpp"
#include "peglib.h"
#include "systems.hpp"

namespace doir {
	bool module::parse(peg::parser& parser, std::string_view source, std::string_view path /*= "generated.doir"*/) {
		auto backup = working_file;
		working_file = path;
		this->source = source;
		auto out = parser.parse(source, path.data());
		working_file = backup;
		return out;
	}

	bool module::parse_file(peg::parser& parser, std::string_view path) {
		return parse(parser, doir::file_manager::singleton().get_file_string(path), path);
	}

	bool module::flags_set(ecrs::entity_t e, decltype(doir::flags{}.as_underlying()) check) {
		if(!has_component<doir::flags>(e)) return false;
		return (get_component<doir::flags>(e).as_underlying() & check) > 0;
	}

	void substitute_entities_impl(module& mod, ecrs::entity_t subtree, const std::unordered_map<ecrs::entity_t, ecrs::entity_t>& substitutions, size_t depth, size_t max_depth) {
		for(auto [to_find, to_replace]: substitutions) {
			if(mod.has_component<doir::block>(subtree)){
				auto& haystack = mod.get_component<doir::block>(subtree);
				for(auto& e: haystack.related)
					if(e == to_find) e = to_replace;
			}
			if(mod.has_component<doir::parent>(subtree)){
				auto& haystack = mod.get_component<doir::parent>(subtree);
				for(auto& e: haystack.related)
					if(e == to_find) e = to_replace;
			}
			if(mod.has_component<doir::function_return_type>(subtree)){
				auto& haystack = mod.get_component<doir::function_return_type>(subtree);
				for(auto& e: haystack.related)
					if(e == to_find) e = to_replace;
			};
			if(mod.has_component<doir::function_inputs>(subtree)){
				auto& haystack = mod.get_component<doir::function_inputs>(subtree);
				for(auto& e: haystack.related)
					if(e == to_find) e = to_replace;
			};
			if(mod.has_component<doir::alias>(subtree)){
				auto& haystack = mod.get_component<doir::alias>(subtree);
				for(auto& e: haystack.related)
					if(e == to_find) e = to_replace;
			}
			if(mod.has_component<doir::type_of>(subtree)){
				auto& haystack = mod.get_component<doir::type_of>(subtree);
				for(auto& e: haystack.related)
					if(e == to_find) e = to_replace;
			}
			if(mod.has_component<doir::call>(subtree)){
				auto& haystack = mod.get_component<doir::call>(subtree);
				for(auto& e: haystack.related)
					if(e == to_find) e = to_replace;
			}


			if(mod.has_component<doir::lookup::lookup>(subtree)){
				auto& lookup = mod.get_component<doir::lookup::lookup>(subtree);
				if(lookup.resolved() && lookup.entity() == to_find)
					lookup = to_replace;
			}
			if(mod.has_component<doir::lookup::function_return_type>(subtree)){
				auto& lookup = mod.get_component<doir::lookup::function_return_type>(subtree);
				if(lookup.resolved() && lookup.entity() == to_find)
					lookup = {to_replace};
			}
			if(mod.has_component<doir::lookup::function_inputs>(subtree)){
				auto& lookups = mod.get_component<doir::lookup::function_inputs>(subtree);
				for(auto& lookup: lookups)
					if(lookup.resolved() && lookup.entity() == to_find)
						lookup = to_replace;
			}
			if(mod.has_component<doir::lookup::alias>(subtree)){
				auto& lookup = mod.get_component<doir::lookup::alias>(subtree);
				if(lookup.resolved() && lookup.entity() == to_find)
					lookup = {to_replace};
			}
			if(mod.has_component<doir::lookup::type_of>(subtree)){
				auto& lookup = mod.get_component<doir::lookup::type_of>(subtree);
				if(lookup.resolved() && lookup.entity() == to_find)
					lookup = {to_replace};
			}
			if(mod.has_component<doir::lookup::call>(subtree)){
				auto& lookup = mod.get_component<doir::lookup::call>(subtree);
				if(lookup.resolved() && lookup.entity() == to_find)
					lookup = {to_replace};
			}
		}

		if(depth < max_depth && mod.has_component<doir::block>(subtree)) {
			for(auto& e: mod.get_component<doir::block>(subtree).related)
				substitute_entities_impl(mod, e, substitutions, depth + 1, max_depth);
		}
	}

	void module::substitute_entities(ecrs::entity_t range, const std::unordered_map<ecrs::entity_t, ecrs::entity_t>& substitutions, size_t max_depth /* = -1*/) {
		if(range == current_canonicalize_root) range = canonicalize::new_root;
		substitute_entities_impl(*this, range, substitutions, 0, max_depth);
	}
}
