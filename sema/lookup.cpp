#define NOMINMAX
#define WIN32_LEAN_AND_MEAN

#include "lookup.hpp"
#include "interface.hpp"
#include "../systems.hpp"
#include "function_arity.hpp"

namespace doir {

	

	namespace sema {
		bool resolve_lookups(ecrs::context& ctx, ecrs::entity_t e, bool types_only) {
			auto& mod = (doir::module&)ctx; // TODO: Verify cast

			if(mod.has_component<doir::lookup::lookup>(e)) {
				auto& lookup = mod.get_component<doir::lookup::lookup>(e);
				doir::lookup::resolve(mod, lookup, e, true);
			}
			if(mod.has_component<doir::lookup::function_return_type>(e)) {
				auto& lookup = mod.get_component<doir::lookup::function_return_type>(e);
				doir::lookup::resolve(mod, lookup, e); // Not strict so that returns can find their parameters
			}
			if(mod.has_component<doir::lookup::call>(e)) {
				auto& lookup = mod.get_component<doir::lookup::call>(e);
				doir::lookup::resolve(mod, lookup, e, true);
			}
			if(mod.has_component<doir::lookup::function_inputs>(e)) {
				bool should_resolve = mod.has_component<doir::type_definition>(e) || !types_only;
				if(!should_resolve && (mod.has_component<doir::call>(e) || mod.has_component<doir::lookup::call>(e))) {
					doir::lookup::lookup lookup = mod.has_component<doir::call>(e)
						? doir::lookup::lookup(mod.get_component<doir::call>(e).related[0])
						: doir::lookup::lookup(mod.get_component<doir::lookup::call>(e));
					if(lookup.resolved()) {
						auto func = lookup.entity();
						should_resolve = block_builder::get_type_modifiers(mod, e).contains(func);
					}
				}

				if(should_resolve) {
					auto& lookups = mod.get_component<doir::lookup::function_inputs>(e);
					for(auto& lookup: lookups)
						doir::lookup::resolve(mod, lookup, e); // Not strict so that parameters can find their neighbors
				}
			}
			if(!types_only && mod.has_component<doir::lookup::alias>(e)) {
				auto& lookup = mod.get_component<doir::lookup::alias>(e);
				doir::lookup::resolve(mod, lookup, e, true);
			}
			if(mod.has_component<doir::lookup::type_of>(e)) {
				auto& lookup = mod.get_component<doir::lookup::type_of>(e);
				doir::lookup::resolve(mod, lookup, e, true);
			}

			// if(mod.has_component<doir::call>(e) || mod.has_component<doir::lookup::call>(e))
			// 	if(mod.has_component<doir::function_inputs>(e) || mod.has_component<doir::lookup::function_inputs>(e)) {
			// 		doir::lookup::lookup call = mod.has_component<doir::call>(e)
			// 			? doir::lookup::lookup(mod.get_component<doir::call>(e).related[0])
			// 			: doir::lookup::lookup(mod.get_component<doir::lookup::call>(e));
			// 		if(!call.resolved()) return true;

			// 		auto decl = call.entity();
			// 		if(!mod.has_component<doir::block>(decl)) return true;
			// 		doir::lookup::lookup lookup = mod.has_component<doir::type_of>(decl)
			// 			? doir::lookup::lookup(mod.get_component<doir::type_of>(decl).related[0])
			// 			: doir::lookup::lookup(mod.get_component<doir::lookup::type_of>(decl));
			// 		if(!lookup.resolved()) return true;
			// 		auto type = sema::validate::resolve_type_modifications(mod, lookup.entity());

			// 		if( !(mod.has_component<doir::function_return_type>(decl) || mod.has_component<doir::lookup::function_return_type>(decl)) ) {
			// 			if(mod.has_component<doir::function_return_type>(decl))
			// 				mod.add_component<doir::function_return_type>(decl) = mod.get_component<doir::function_return_type>(type);
			// 			else if(mod.has_component<doir::lookup::function_return_type>(decl))
			// 				mod.add_component<doir::lookup::function_return_type>(decl) = mod.get_component<doir::lookup::function_return_type>(type);
			// 		}

			// 		if( !(mod.has_component<doir::function_inputs>(type) || mod.has_component<doir::lookup::function_inputs>(type)) ) return true;
			// 		auto inputs = mod.has_component<doir::function_inputs>(type)
			// 			? doir::lookup::function_inputs::to_lookup(mod.get_component<doir::function_inputs>(type))
			// 			: mod.get_component<doir::lookup::function_inputs>(type);
			// 		auto params = inputs.associated_parameters(mod, mod.get_component<doir::block>(decl));
			// 		if(params.size()) return true;

			// 		doir::function_builder builder{decl, &mod};
			// 		builder.push_parameters(type);
			// 	}

			return true;
		}

		bool validate::lookups_resolved(ecrs::context& ctx, ecrs::entity_t e) {
			auto& mod = (doir::module&)ctx; // TODO: Verify cast

			bool valid = true;
			if(mod.has_component<doir::lookup::lookup>(e)) {
				auto& lookup = mod.get_component<doir::lookup::lookup>(e);
				if(!lookup.resolved()) {
					auto& diag = push_diagnostic(doir::diagnostic_type::FailedToResolveLookup, doir::find_detailed_source_location(mod, e), mod.source, mod.working_file.value_or(invalid_file_name));
					diagnose::diagnostic::annotation annotation;
					annotation.message = std::string("Object ") + doir::ansi::info + std::string(lookup.name()) + diagnose::ansi::reset + " appears to not exist";
					annotation.position = diag.location.start;
					diag.annotations.push_back(annotation);
					valid = false;
				}
			}
			if(mod.has_component<doir::lookup::function_return_type>(e)) {
				auto& lookup = mod.get_component<doir::lookup::function_return_type>(e);
				if(lookup.resolved()) {
					mod.add_component<doir::function_return_type>(e).related = {lookup.entity()};
					mod.remove_component<doir::lookup::function_return_type>(e);
				} else {
					auto& diag = push_diagnostic(doir::diagnostic_type::FailedToResolveLookup, doir::find_detailed_source_location(mod, e), mod.source, mod.working_file.value_or(invalid_file_name));
					diagnose::diagnostic::annotation annotation;
					annotation.message = std::string("Type ") + doir::ansi::info + std::string(lookup.name()) + diagnose::ansi::reset + " appears to not exist";
					annotation.position = diag.location.start;
					diag.annotations.push_back(annotation);
					valid = false;
				}
			}
			if(mod.has_component<doir::lookup::function_inputs>(e)) {
				auto& lookups = mod.get_component<doir::lookup::function_inputs>(e);
				for(auto& lookup: lookups)
					if(!lookup.resolved()) {
						auto& diag = push_diagnostic(doir::diagnostic_type::FailedToResolveLookup, doir::find_detailed_source_location(mod, e), mod.source, mod.working_file.value_or(invalid_file_name));
						diagnose::diagnostic::annotation annotation;
						annotation.message = std::string("Function argument ") + doir::ansi::info + std::string(lookup.name()) + diagnose::ansi::reset + " appears to not exist";
						annotation.position = diag.location.start;
						diag.annotations.push_back(annotation);
						valid = false;
					}

				if(valid) {
					auto& old = mod.get_component<doir::lookup::function_inputs>(e);
					auto& new_ = mod.add_component<doir::function_inputs>(e);
					new_.related.reserve(old.size());
					for(size_t i = 0; i < old.size(); ++i)
						new_.related.push_back(old[i].entity());
					mod.remove_component<doir::lookup::function_inputs>(e);
				}
			}
			if(mod.has_component<doir::lookup::alias>(e)) {
				auto& lookup = mod.get_component<doir::lookup::alias>(e);
				if(lookup.resolved()) {
					mod.add_component<doir::alias>(e).related = {lookup.entity()};
					mod.remove_component<doir::lookup::alias>(e);
				} else {
					auto& diag = push_diagnostic(doir::diagnostic_type::FailedToResolveLookup, doir::find_detailed_source_location(mod, e), mod.source, mod.working_file.value_or(invalid_file_name));
					diagnose::diagnostic::annotation annotation;
					annotation.message = std::string("Alias ") + doir::ansi::info + std::string(lookup.name()) + diagnose::ansi::reset + " appears to not exist";
					annotation.position = diag.location.start;
					diag.annotations.push_back(annotation);
					valid = false;
				}
			}
			if(mod.has_component<doir::lookup::type_of>(e)) {
				auto& lookup = mod.get_component<doir::lookup::type_of>(e);
				if(lookup.resolved()) {
					mod.add_component<doir::type_of>(e).related = {lookup.entity()};
					mod.remove_component<doir::lookup::type_of>(e);
				} else {
					auto& diag = push_diagnostic(doir::diagnostic_type::FailedToResolveLookup, doir::find_detailed_source_location(mod, e), mod.source, mod.working_file.value_or(invalid_file_name));
					diagnose::diagnostic::annotation annotation;
					annotation.message = std::string("Type ") + doir::ansi::info + std::string(lookup.name()) + diagnose::ansi::reset + " appears to not exist";
					annotation.position = diag.location.start;
					diag.annotations.push_back(annotation);
					valid = false;
				}
			}
			if(mod.has_component<doir::lookup::call>(e)) {
				auto& lookup = mod.get_component<doir::lookup::call>(e);
				if(lookup.resolved()) {
					mod.add_component<doir::call>(e).related = {lookup.entity()};
					mod.remove_component<doir::lookup::call>(e);
				} else {
					auto location = doir::find_source_location(mod, e);
					auto& diag = push_diagnostic(doir::diagnostic_type::FailedToResolveLookup, location, mod.source, mod.working_file.value_or(invalid_file_name));
					diagnose::diagnostic::annotation annotation;
					annotation.message = std::string("Function ") + doir::ansi::info + std::string(lookup.name()) + diagnose::ansi::reset + " appears to not exist";
					auto start = mod.source.substr(location.start_byte, location.end_byte - location.start_byte).find(lookup.name());
					if(start != std::string::npos) 
						location.start_byte += start;
					annotation.position = location.start(mod.source);
					diag.annotations.push_back(annotation);
					valid = false;
				}
			}

			return valid;
		}
	}
}
