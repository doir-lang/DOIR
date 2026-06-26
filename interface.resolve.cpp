#define NOMINMAX
#define WIN32_LEAN_AND_MEAN

#include "interface.hpp"
#include "module.hpp"
#include "string_helpers.hpp"
#include "diagnostics.hpp"

#include <unordered_map>

namespace doir {

	diagnose::source_location find_source_location(module& mod, ecrs::entity_t subtree) {
		if(mod.has_component<diagnose::source_location::detailed>(subtree))
			return mod.get_component<diagnose::source_location::detailed>(subtree).to_bytes(mod.source);

		if(mod.has_component<diagnose::source_location>(subtree))
			return mod.get_component<diagnose::source_location>(subtree);

		if(mod.has_component<doir::name>(subtree)) {
			auto& name = mod.get_component<doir::name>(subtree);
			auto start = mod.source.find(name);
			if(start == std::string::npos) {
				throw std::runtime_error("Failed to generate source location for entity: " + std::to_string(subtree));
			}
			auto end = start + name.size();

			return diagnose::source_location{mod.working_file.value_or(invalid_file_name), start, end};
		}

		throw std::runtime_error("Failed to generate source location for entity: " + std::to_string(subtree));
	}
	diagnose::source_location::detailed find_detailed_source_location(module& mod, ecrs::entity_t subtree) {
		// This prevents us from following the expensive path which converts a detailed to byte in the other function
		if(mod.has_component<diagnose::source_location::detailed>(subtree))
			return mod.get_component<diagnose::source_location::detailed>(subtree);

		return find_source_location(mod, subtree).to_detailed(mod.source);
	}
	
	ecrs::entity_t find_block(const doir::module& mod, ecrs::entity_t e, ecrs::entity_t must_contain /*= ecrs::invalid_entity*/) {
		if(mod.has_component<doir::block>(e)) {
			auto& block = mod.get_component<doir::block>(e);
			if(must_contain == ecrs::invalid_entity)
				return e;
			else if(std::find(block.related.begin(), block.related.end(), must_contain) != block.related.end())
				return e;
		}
		if(e > mod.entity_count())
			return ecrs::invalid_entity;
		// TODO: How terrible of an idea is it to implement this recursively?
		return find_block(mod, e + 1, must_contain);
	}

	ecrs::entity_t find_parent(const doir::module& mod, ecrs::entity_t e) {
		if(mod.has_component<doir::parent>(e))
			return find_block(mod, mod.get_component<doir::parent>(e).related[0]);
		else return find_block(mod, e, e);
	}

	// Returns
	ecrs::entity_t find_function_inside_of(const doir::module& mod, ecrs::entity_t subtree) {
		ecrs::entity_t last = ecrs::invalid_entity;
		while(subtree != ecrs::invalid_entity && subtree != last) {
			if(mod.has_component<doir::function_return_type>(subtree))
				return subtree;
			if(mod.has_component<doir::type_of>(subtree))
				if(auto type = mod.get_component<doir::type_of>(subtree).related[0];
					mod.has_component<doir::function_return_type>(resolve_type_modifications(mod, type))
				)
					return subtree;
			subtree = find_parent(mod, last = subtree);
		}
		return ecrs::invalid_entity;
	}

	inline ecrs::entity_t find_namespace(const doir::module& mod, const doir::block& block, std::string_view name) {
		for(auto e: block.related)
			if(mod.has_component<doir::name>(e)) {
				std::string_view e_name = mod.get_component<doir::name>(e);
				if(e_name == name && mod.has_component<doir::flags>(e) && mod.get_component<doir::flags>(e).namespace_set())
					return e;
			}
		return ecrs::invalid_entity;
	}

	inline ecrs::entity_t find_name_in_block(const doir::module& mod, const doir::block& block, std::string_view name) {
		for(auto e: block.related)
			if(mod.has_component<doir::name>(e)) {
				auto e_name = mod.get_component<doir::name>(e);
				if (e_name == name)
					return e;
			}
		return ecrs::invalid_entity;
	}

	ecrs::entity_t lookup::resolve(const doir::module& mod, doir::interned_string lookup, ecrs::entity_t search_start, bool strict /*= false*/) {
		auto block = find_block(mod, search_start, strict ? search_start : ecrs::invalid_entity);
		if(block == ecrs::invalid_entity)
			return block;

		auto namespaces = diagnose::split(lookup, '.');
		auto name = mod.interner.intern(namespaces.back());
		namespaces.pop_back();

		ecrs::entity_t Namespace = block;
		if(namespaces.size()) {
			do {
				Namespace = find_namespace(mod, mod.get_component<doir::block>(block), mod.interner.intern(namespaces.front()));

				if(Namespace == ecrs::invalid_entity) {
					if(mod.has_component<doir::parent>(block))
						block = find_block(mod, mod.get_component<doir::parent>(block).related[0]);
					else block = find_block(mod, block + 1);

					if (block == ecrs::invalid_entity)
						return ecrs::invalid_entity;
				}
			} while(Namespace == ecrs::invalid_entity);

			namespaces.erase(namespaces.begin());
			for(auto name: namespaces) {
				Namespace = find_namespace(mod, mod.get_component<doir::block>(Namespace), mod.interner.intern(name));
				if(Namespace == ecrs::invalid_entity)
					return ecrs::invalid_entity;
			}

			return find_name_in_block(mod, mod.get_component<doir::block>(Namespace), name);
		}

		while (block < mod.entity_count() && block != ecrs::invalid_entity) {
			if(auto res = find_name_in_block(mod, mod.get_component<doir::block>(block), name); res != ecrs::invalid_entity)
				return res;

			if(mod.has_component<doir::parent>(block))
				block = find_block(mod, mod.get_component<doir::parent>(block).related[0]);
			else block = find_block(mod, block + 1);
		}

		return ecrs::invalid_entity;
	}

	ecrs::entity_t lookup::resolve(const doir::module& mod, doir::lookup::lookup& lookup, ecrs::entity_t search_start, bool strict /*= false*/) {
		if(lookup.resolved()) return lookup.entity();

		auto out = resolve(mod, lookup.name(), search_start, strict);
		if(out == ecrs::invalid_entity) return ecrs::invalid_entity;

		lookup = out;
		return out;
	}

	ecrs::entity_t resolve_type_modifications(const doir::module& mod, ecrs::entity_t type) {
		while(mod.has_component<doir::call>(type) || mod.has_component<doir::lookup::call>(type)) {
			doir::lookup::lookup call = mod.has_component<doir::call>(type)
				? doir::lookup::lookup(mod.get_component<doir::call>(type).related[0])
				: doir::lookup::lookup(mod.get_component<doir::lookup::call>(type));
			if(!call.resolved()) return type;

			auto func = call.entity();
			// If this is a type modifier then we keep resolving
			if(!block_builder::get_type_modifiers(mod, type).contains(func))
				return type;

			auto inputs = mod.has_component<doir::function_inputs>(type)
				? doir::lookup::function_inputs::to_lookup(mod.get_component<doir::function_inputs>(type))
				: mod.get_component<doir::lookup::function_inputs>(type);
			if(!inputs[0].resolved()) return type;
			type = inputs[0].entity();
		}
		return type;
	}

	ecrs::entity_t type_definition::base_type(const module& mod, ecrs::entity_t e) {
		e = alias::resolve(mod, e);

		if(mod.has_component<doir::pointer>(e)) 
			return base_type(mod, mod.get_component<doir::pointer>(e).related[0]);

		return e;
	}

	ecrs::entity_t alias::resolve(const module& mod, ecrs::entity_t alias) {
		while(mod.has_component<doir::alias>(alias))
			alias = mod.get_component<doir::alias>(alias).related[0];
		return alias;
	}

	std::vector<ecrs::entity_t> alias::resolve(const module& mod, std::vector<ecrs::entity_t> aliases) {
		for(auto& alias: aliases)
			alias = resolve(mod, alias);
		return aliases;
	}

} // namespace doir
