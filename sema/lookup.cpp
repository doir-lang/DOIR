#define NOMINMAX
#define WIN32_LEAN_AND_MEAN

#include "lookup.hpp"
#include "util.hpp"

namespace doir {
	inline ecrs::entity_t find_block(doir::module& mod, ecrs::entity_t e) {
		if(mod.has_component<doir::block>(e))
			return e;
		if(e > mod.entity_count())
			return ecrs::invalid_entity;
		// TODO: How terrible of an idea is it to implement this recursively?
		return find_block(mod, e + 1);
	}

	inline ecrs::entity_t find_namespace(doir::module& mod, doir::block& block, std::string_view name) {
		for(auto e: block.related)
			if(mod.has_component<doir::name>(e)) {
				std::string_view e_name = mod.get_component<doir::name>(e);
				if(e_name == name && mod.has_component<doir::flags>(e) && mod.get_component<doir::flags>(e).namespace_set())
					return e;
			}
		return ecrs::invalid_entity;
	}

	inline ecrs::entity_t find_name_in_block(doir::module& mod, doir::block& block, std::string_view name) {
		for(auto e: block.related)
			if(mod.has_component<doir::name>(e)) {
				auto e_name = mod.get_component<doir::name>(e);
				if (e_name == name)
					return e;
			}
		return ecrs::invalid_entity;
	}

	ecrs::entity_t lookup::resolve(doir::module& mod, doir::interned_string lookup, ecrs::entity_t search_start) {
		auto block = find_block(mod, search_start);
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

	ecrs::entity_t lookup::resolve(doir::module& mod, doir::lookup::lookup& lookup, ecrs::entity_t search_start) {
		if(lookup.resolved()) return lookup.entity();

		auto out = resolve(mod, lookup.name(), search_start);
		if(out == ecrs::invalid_entity) return ecrs::invalid_entity;

		lookup = out;
		return out;
	}

	namespace sema {
		bool resolve_lookups_impl(doir::module& mod, ecrs::entity_t e) {
			if(mod.has_component<doir::lookup::lookup>(e)) {
				auto& lookup = mod.get_component<doir::lookup::lookup>(e);
				doir::lookup::resolve(mod, lookup, e);
			}
			if(mod.has_component<doir::lookup::function_return_type>(e)) {
				auto& lookup = mod.get_component<doir::lookup::function_return_type>(e);
				doir::lookup::resolve(mod, lookup, e);
			}
			if(mod.has_component<doir::lookup::function_inputs>(e)) {
				auto& lookups = mod.get_component<doir::lookup::function_inputs>(e);
				for(auto& lookup: lookups)
					doir::lookup::resolve(mod, lookup, e);
			}
			if(mod.has_component<doir::lookup::alias>(e)) {
				auto& lookup = mod.get_component<doir::lookup::alias>(e);
				doir::lookup::resolve(mod, lookup, e);
			}
			if(mod.has_component<doir::lookup::type_of>(e)) {
				auto& lookup = mod.get_component<doir::lookup::type_of>(e);
				doir::lookup::resolve(mod, lookup, e);
			}
			if(mod.has_component<doir::lookup::call>(e)) {
				auto& lookup = mod.get_component<doir::lookup::call>(e);
				doir::lookup::resolve(mod, lookup, e);
			}

			return true;
		}

		DOIR_MAKE_SORTED_WALKER(resolve_lookups, false)
	}
}
