#include "fp/pointer.hpp"
#include <optional>
#include <stdexcept>
#include <string_view>
#include <unordered_set>
#define NOMINMAX
#define WIN32_LEAN_AND_MEAN

#include "interface.hpp"
#include "module.hpp"
#include "diagnostics.hpp"
#include "string_helpers.hpp"

#include <unordered_map>

namespace doir::verify {

	diagnose::source_location get_location(module& mod, std::string_view s) {
		size_t start;
		if(contains(mod.source, s))
			start = mod.source.data() - s.data();
		else start = mod.source.find(s);

		if(start == std::string_view::npos)
			return {mod.working_file.value_or("<unknown>"), 0, 0};
		return {mod.working_file.value_or("<unknown>"), start, start + s.length()};
	}

	bool entity_exists(diagnose::manager &diagnostics, module &mod, ecrs::entity_t root) {
		if( !(root <= mod.entity_count()) ) {
			throw std::runtime_error("TODO: invalid entity error");
			return false;
		}
		if(mod.freelist && fp::contains(mod.freelist.begin(), mod.freelist.end(), root)) {
			throw std::runtime_error("TODO: entity removed error");
			return false;
		}
		return true;
	}

	bool identifier_structure(diagnose::manager &diagnostics, module &mod, interned_string ident, bool allow_builtins /*= true*/) {
		using namespace std::string_literals;
		std::string invalid_message = "";
		size_t invalid_offset;

		if(ident[0] == '%') {
			if(ident.size() == 1) {
				invalid_message = "A "s + doir::ansi::info + "%" + diagnose::ansi::reset + " in an identifier must by followed by a number";
				invalid_offset = 0;
			}
			for(size_t i = 1; i < ident.size(); ++i)
				if(!std::isdigit(ident[i])) {
					invalid_message = "Only numbers can follow a "s + doir::ansi::info + "%" + diagnose::ansi::reset;
					invalid_offset = i;
					break;
				}
		}

		if(!allow_builtins) {
			std::unordered_set<std::string_view> builtins = DOIR_BUILTIN_NAMES;
			if(builtins.contains(ident)) {
				invalid_message = "Reserved identifier "s + doir::ansi::type + std::string(ident) + diagnose::ansi::reset + " not allowed here";
				invalid_offset = 0;
			}
		}

		if(!invalid_message.empty()) {
			auto& diag = diagnostics.push(generate_diagnostic(diagnostic_type::InvalidIdentifier, get_location(mod, ident), mod.source, *mod.working_file));
			diag.push_annotation({
				.position = {diag.location.start.line, diag.location.start.column + invalid_offset},
				.message = invalid_message,
				.color = doir::ansi::info,
			});
			return false;
		}

		return true;
	}

	bool verify_lookup_structure(diagnose::manager &diagnostics, module &mod, const lookup::lookup& l) {
		if(l.resolved()) {
			if(!verify::entity_exists(diagnostics, mod, l.entity())) return false;
		} else if(!verify::identifier_structure(diagnostics, mod, l.name())) return false;
		return true;
	}

	bool structure(diagnose::manager& diagnostics, module& mod, ecrs::entity_t root, bool top_level /* = true */) {
		bool valid = false;

		if(mod.has_component<type_of>(root) || mod.has_component<lookup::type_of>(root)) {
			valid = true;

			lookup::type_of t = mod.has_component<type_of>(root)
				? lookup::type_of(mod.get_component<type_of>(root).related[0])
				: mod.get_component<lookup::type_of>(root);

			if(!verify_lookup_structure(diagnostics, mod, t)) valid = false;

			if(mod.has_component<doir::pointer>(root)
				|| mod.has_component<doir::type_definition>(root)
				|| mod.has_component<doir::alias>(root)
				|| mod.has_component<doir::lookup::lookup>(root)
				|| mod.has_component<doir::lookup::alias>(root)
			){
				throw std::runtime_error("TODO: Invalid component");
				valid = false;
			}

			bool valueless = mod.has_component<doir::valueless>(root);
			bool number = mod.has_component<doir::number>(root);
			bool string = mod.has_component<doir::string>(root);
			bool call = mod.has_component<doir::call>(root);
			bool call_lookup = mod.has_component<doir::lookup::call>(root);
			bool function_def = mod.has_component<doir::function_return_type>(root);
			bool function_def_lookup = mod.has_component<doir::lookup::function_return_type>(root);
			bool block = mod.has_component<doir::block>(root);

			if( (call || call_lookup || function_def || function_def_lookup || block) && mod.has_component<doir::function_parameter>(root)) {
				// TODO: Should we maintain this rule?
				throw std::runtime_error("TODO: Parameters can only have a string, a number, or nothing as a default value");
				valid = false;
			}

			size_t count = valueless + number + string + call + call_lookup + function_def + function_def_lookup + block;
			switch(count) {
			break; case 0:
				throw std::runtime_error("TODO: Value required error");
				valid = false;
			break; case 1:
				// Do Nothing we are good :)
			break; case 2:
				if( !((function_def && block) || (function_def_lookup && block)) ) {
					throw std::runtime_error("TODO: Only one value is allowed error");
					valid = false;
				}
			break; default:
				throw std::runtime_error("TODO: Only one value is allowed error");
				valid = false;
			}

			auto flags = mod.has_component<doir::flags>(root)
				? std::optional<doir::flags>(mod.get_component<doir::flags>(root))
				: std::optional<doir::flags>{};
			if( !(call || call_lookup || function_def || function_def_lookup) && flags) {
				if(flags->flatten_set() || flags->inline_set() || flags->pure_set() || flags->tail_set()) {
					throw std::runtime_error("TODO: Invalid flags");
					valid = false;
				}
			}
			if(flags && flags->constant_set()) {
				throw std::runtime_error("TODO: Only pointer types can be marked constant");
				valid = false;
			}

			if(call || call_lookup) {
				doir::lookup::lookup call = mod.has_component<doir::call>(root)
					? doir::lookup::lookup(mod.get_component<doir::call>(root).related[0])
					: doir::lookup::lookup(mod.get_component<doir::lookup::call>(root));
				if(call.resolved() && !verify::structure(diagnostics, mod, call.entity(), false)) valid = false;
				auto inputs = mod.has_component<doir::function_inputs>(root)
					? doir::lookup::function_inputs::to_lookup(mod.get_component<doir::function_inputs>(root))
					: mod.get_component<doir::lookup::function_inputs>(root);
				for(auto& i: inputs)
					if(i.resolved() && !verify::structure(diagnostics, mod, i.entity(), false)) valid = false;

			} else if(function_def || function_def_lookup) {
				if(!t.resolved()) {
					throw std::runtime_error("TODO: function types can't be looked up");
					return false;
				}
				if(!verify::structure(diagnostics, mod, t.entity(), false)) valid = false;

				auto inputs = mod.has_component<doir::function_inputs>(t.entity())
					? doir::lookup::function_inputs::to_lookup(mod.get_component<doir::function_inputs>(t.entity()))
					: mod.get_component<doir::lookup::function_inputs>(t.entity());

				if(mod.has_component<doir::block>(root)
					&& inputs.associated_parameters(mod, mod.get_component<doir::block>(root)).size() != inputs.size()
				) {
					throw std::runtime_error("TODO: A different number of parameters are defined than declared.");
					valid = false;
				}
			}

		} else if(mod.has_component<type_definition>(root)) {
			valid = true;

			if( !(mod.has_component<doir::block>(root)
				|| mod.has_component<doir::function_return_type>(root)
				|| mod.has_component<doir::lookup::function_return_type>(root) // TODO: Valid?
				// || mod.has_component<doir::call>(root)
				// || mod.has_component<doir::lookup::call>(root)
			) ) {
				std::cout << root << std::endl;
				throw std::runtime_error("Types are required to have a `block` while function types are required to have a `function_inputs`");
				valid = false;
			}

			if(mod.has_component<doir::valueless>(root)
				|| mod.has_component<doir::pointer>(root)
				|| mod.has_component<doir::function_parameter>(root)
				|| mod.has_component<doir::block>(root)
				|| mod.has_component<doir::alias>(root)
				|| mod.has_component<doir::type_of>(root)
				|| mod.has_component<doir::number>(root)
				|| mod.has_component<doir::string>(root)
				|| mod.has_component<doir::call>(root)
				|| mod.has_component<doir::lookup::lookup>(root)
				// || mod.has_component<doir::lookup::block>(root)
				|| mod.has_component<doir::lookup::alias>(root)
				|| mod.has_component<doir::lookup::type_of>(root)
				|| mod.has_component<doir::lookup::call>(root)
			){
				throw std::runtime_error("TODO: Invalid component attached");
				valid = false;
			}

			if(mod.has_component<doir::function_inputs>(root)) {
				auto inputs = mod.has_component<doir::function_inputs>(root)
					? doir::lookup::function_inputs::to_lookup(mod.get_component<doir::function_inputs>(root))
					: mod.get_component<doir::lookup::function_inputs>(root);
				std::optional<doir::lookup::function_return_type> return_type = {};
				if(mod.has_component<doir::function_return_type>(root))
					return_type = {mod.get_component<doir::function_return_type>(root).related[0]};
				else if(mod.has_component<doir::lookup::function_return_type>(root))
					return_type = mod.get_component<doir::lookup::function_return_type>(root);

				if(return_type && return_type->resolved() && !verify::structure(diagnostics, mod, return_type->entity(), false))
					valid = false;
				for(auto& i: inputs)
					if(i.resolved() && !verify::structure(diagnostics, mod, i.entity(), false)) valid = false;
			}

			// TODO: What flags are valid?

		} else if(mod.has_component<Namespace>(root)) {
			valid = true;

			if(!mod.has_component<doir::block>(root)) {
				throw std::runtime_error("Namespaces are required to have a block");
				valid = false;
			}

			if(mod.has_component<doir::flags>(root)) {
				auto flags = mod.get_component<doir::flags>(root).flags;
				if( !(flags == doir::flags::None || flags == doir::flags::Export) ) {
					throw std::runtime_error("Invalid flags");
					valid = false;
				}
			}

			if(mod.has_component<doir::valueless>(root)
				|| mod.has_component<doir::pointer>(root)
				|| mod.has_component<doir::function_return_type>(root)
				|| mod.has_component<doir::function_inputs>(root)
				|| mod.has_component<doir::function_parameter>(root)
				|| mod.has_component<doir::type_definition>(root)
				|| mod.has_component<doir::alias>(root)
				|| mod.has_component<doir::type_of>(root)
				|| mod.has_component<doir::number>(root)
				|| mod.has_component<doir::string>(root)
				|| mod.has_component<doir::call>(root)
				|| mod.has_component<doir::lookup::lookup>(root)
				|| mod.has_component<doir::lookup::function_return_type>(root)
				|| mod.has_component<doir::lookup::function_inputs>(root)
				// || mod.has_component<doir::lookup::block>(root)
				|| mod.has_component<doir::lookup::alias>(root)
				|| mod.has_component<doir::lookup::type_of>(root)
				|| mod.has_component<doir::lookup::call>(root)
			){
				throw std::runtime_error("TODO: Invalid component attached");
				valid = false;
			}

		} else if(mod.has_component<alias>(root) || mod.has_component<doir::lookup::alias>(root)) {
			if(mod.has_component<doir::valueless>(root)
				|| mod.has_component<doir::pointer>(root)
				|| mod.has_component<doir::function_return_type>(root)
				|| mod.has_component<doir::function_inputs>(root)
				|| mod.has_component<doir::function_parameter>(root)
				|| mod.has_component<doir::block>(root)
				|| mod.has_component<doir::type_definition>(root)
				|| mod.has_component<doir::Namespace>(root)
				|| mod.has_component<doir::type_of>(root)
				|| mod.has_component<doir::number>(root)
				|| mod.has_component<doir::string>(root)
				|| mod.has_component<doir::call>(root)
				|| mod.has_component<doir::lookup::lookup>(root)
				|| mod.has_component<doir::lookup::function_return_type>(root)
				|| mod.has_component<doir::lookup::function_inputs>(root)
				// || mod.has_component<doir::lookup::block>(root)
				|| mod.has_component<doir::lookup::type_of>(root)
				|| mod.has_component<doir::lookup::call>(root)
			){
				throw std::runtime_error("TODO: Invalid component attached");
				valid = false;
			}

			if(mod.has_component<doir::flags>(root)) {
				auto flags = mod.get_component<doir::flags>(root).flags;
				if( !(flags == doir::flags::None || flags == doir::flags::Export) ) {
					throw std::runtime_error("Invalid flags");
					valid = false;
				}
			}

			auto alias = mod.has_component<doir::alias>(root)
				? lookup::alias(mod.get_component<doir::alias>(root).related[0])
				: mod.get_component<lookup::alias>(root);

			if(alias.resolved())
				return verify::structure(diagnostics, mod, alias.entity(), false);

		} else if(mod.has_component<block>(root)) {
			if(top_level)
				valid = true;
			else {
				throw std::runtime_error("TODO: A standalone block not as part of an assignment is only allowed at the top level!");
				valid = false;
			}
		}

		if(fp::contains(mod.freelist.begin(), mod.freelist.end(), root)) {
			throw std::runtime_error("TODO: Referenced deleted entity");
			valid = false;
		}

		if(mod.has_component<name>(root))
			if(!verify::identifier_structure(diagnostics, mod, mod.get_component<name>(root), false)) valid = false;

		if(mod.has_component<doir::block>(root)) for(auto e: mod.get_component<doir::block>(root).related)
			if(!verify::structure(diagnostics, mod, e))
				valid = false;

		return valid;
	}
} // namespace doir
