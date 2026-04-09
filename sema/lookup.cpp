#define NOMINMAX
#define WIN32_LEAN_AND_MEAN

#include "lookup.hpp"
#include "../systems.hpp"
#include "function_arity.hpp"

namespace doir {
	ecrs::entity_t find_block(const doir::module& mod, ecrs::entity_t e) {
		if(mod.has_component<doir::block>(e))
			return e;
		if(e > mod.entity_count())
			return ecrs::invalid_entity;
		// TODO: How terrible of an idea is it to implement this recursively?
		return find_block(mod, e + 1);
	}

	ecrs::entity_t find_parent(const doir::module& mod, ecrs::entity_t e) {
		if(mod.has_component<doir::parent>(e))
			return find_block(mod, mod.get_component<doir::parent>(e).related[0]);
		else return find_block(mod, e);
	}

	// Returns
	ecrs::entity_t find_function_inside_of(const doir::module& mod, ecrs::entity_t subtree) {
		ecrs::entity_t last = ecrs::invalid_entity;
		while(subtree != ecrs::invalid_entity && subtree != last) {
			if(mod.has_component<doir::function_return_type>(subtree))
				return subtree;
			if(mod.has_component<doir::type_of>(subtree))
				if(auto type = mod.get_component<doir::type_of>(subtree).related[0];
					mod.has_component<doir::function_return_type>(sema::validate::resolve_type_modifications(mod, type))
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

	ecrs::entity_t lookup::resolve(const doir::module& mod, doir::interned_string lookup, ecrs::entity_t search_start) {
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

	ecrs::entity_t lookup::resolve(const doir::module& mod, doir::lookup::lookup& lookup, ecrs::entity_t search_start) {
		if(lookup.resolved()) return lookup.entity();

		auto out = resolve(mod, lookup.name(), search_start);
		if(out == ecrs::invalid_entity) return ecrs::invalid_entity;

		lookup = out;
		return out;
	}

	namespace sema {
		bool resolve_lookups(ecrs::context& ctx, ecrs::entity_t e, bool types_only) {
			auto& mod = (doir::module&)ctx; // TODO: Verify cast

			if(mod.has_component<doir::lookup::lookup>(e)) {
				auto& lookup = mod.get_component<doir::lookup::lookup>(e);
				doir::lookup::resolve(mod, lookup, e);
			}
			if(mod.has_component<doir::lookup::function_return_type>(e)) {
				auto& lookup = mod.get_component<doir::lookup::function_return_type>(e);
				doir::lookup::resolve(mod, lookup, e);
			}
			if(mod.has_component<doir::lookup::call>(e)) {
				auto& lookup = mod.get_component<doir::lookup::call>(e);
				doir::lookup::resolve(mod, lookup, e);
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
						doir::lookup::resolve(mod, lookup, e);
				}
			}
			if(!types_only && mod.has_component<doir::lookup::alias>(e)) {
				auto& lookup = mod.get_component<doir::lookup::alias>(e);
				doir::lookup::resolve(mod, lookup, e);
			}
			if(mod.has_component<doir::lookup::type_of>(e)) {
				auto& lookup = mod.get_component<doir::lookup::type_of>(e);
				doir::lookup::resolve(mod, lookup, e);
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

		bool validate::lookups_resolved(ecrs::context& mod, ecrs::entity_t e) {
			bool valid = true;
			if(mod.has_component<doir::lookup::lookup>(e)) {
				auto& lookup = mod.get_component<doir::lookup::lookup>(e);
				if(!lookup.resolved()) {
					throw std::runtime_error("TODO: Failed to resolve lookup");
					valid = false;
				}
			}
			if(mod.has_component<doir::lookup::function_return_type>(e)) {
				auto& lookup = mod.get_component<doir::lookup::function_return_type>(e);
				if(lookup.resolved()) {
					mod.add_component<doir::function_return_type>(e).related = {lookup.entity()};
					mod.remove_component<doir::lookup::function_return_type>(e);
				} else {
					throw std::runtime_error("TODO: Failed to resolve lookup");
					valid = false;
				}
			}
			if(mod.has_component<doir::lookup::function_inputs>(e)) {
				auto& lookups = mod.get_component<doir::lookup::function_inputs>(e);
				for(auto& lookup: lookups)
					if(!lookup.resolved()) {
						throw std::runtime_error("TODO: Failed to resolve lookup");
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
					throw std::runtime_error("TODO: Failed to resolve lookup");
					valid = false;
				}
			}
			if(mod.has_component<doir::lookup::type_of>(e)) {
				auto& lookup = mod.get_component<doir::lookup::type_of>(e);
				if(lookup.resolved()) {
					mod.add_component<doir::type_of>(e).related = {lookup.entity()};
					mod.remove_component<doir::lookup::type_of>(e);
				} else {
					throw std::runtime_error("TODO: Failed to resolve lookup");
					valid = false;
				}
			}
			if(mod.has_component<doir::lookup::call>(e)) {
				auto& lookup = mod.get_component<doir::lookup::call>(e);
				if(lookup.resolved()) {
					mod.add_component<doir::call>(e).related = {lookup.entity()};
					mod.remove_component<doir::lookup::call>(e);
				} else {
					throw std::runtime_error("TODO: Failed to resolve lookup");
					valid = false;
				}
			}

			return valid;
		}
	}
}
