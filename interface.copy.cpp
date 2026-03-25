#define NOMINMAX
#define WIN32_LEAN_AND_MEAN

#include "../module.hpp"
#include "../interface.hpp"

namespace doir {
	void deep_copy_copy_components(module& mod, ecrs::entity_t out, ecrs::entity_t block, std::unordered_map<ecrs::entity_t, ecrs::entity_t>& subtitutions, std::unordered_map<ecrs::entity_t, ecrs::entity_t>& reverse_subtitutions, void(*extra_copy_instructions)(ecrs::entity_t dest, ecrs::entity_t src)) {
		auto subtree = reverse_subtitutions[out];

		mod.get_or_add_component<doir::parent>(out) = {{block}};

		if(mod.has_component<doir::name>(subtree))
			mod.get_or_add_component<doir::name>(out) = mod.get_component<doir::name>(subtree);

		if(mod.has_component<doir::flags>(subtree))
			mod.get_or_add_component<doir::flags>(out) = mod.get_component<doir::flags>(subtree);

		if(mod.has_component<doir::type_of>(subtree) || mod.has_component<doir::lookup::type_of>(subtree)) {
			// Type == back link
			if(mod.has_component<doir::type_of>(subtree)) {
				auto& destination = mod.add_component<doir::type_of>(out);
				auto& source = mod.get_component<doir::type_of>(subtree);
				destination.related[0] = subtitutions.contains(source.related[0]) ? subtitutions[source.related[0]] : source.related[0];
			}
			if(mod.has_component<doir::lookup::type_of>(subtree)) {
				auto& destination = mod.add_component<doir::lookup::type_of>(out);
				auto& lookup = mod.get_component<doir::lookup::type_of>(subtree);
				destination = lookup.resolved() && subtitutions.contains(lookup.entity())
					? doir::lookup::type_of{subtitutions[lookup.entity()]} : lookup;
			}

			if(mod.has_component<doir::function_parameter>(subtree))
				mod.add_component<doir::function_parameter>(out) = mod.get_component<doir::function_parameter>(subtree);

			bool valueless = mod.has_component<doir::flags>(subtree) && mod.get_component<doir::flags>(subtree).valueless_set();
			bool number = mod.has_component<doir::number>(subtree);
			bool string = mod.has_component<doir::string>(subtree);
			bool call = mod.has_component<doir::call>(subtree);
			bool call_lookup = mod.has_component<doir::lookup::call>(subtree);
			bool function_def = mod.has_component<doir::function_return_type>(subtree);
			bool function_def_lookup = mod.has_component<doir::lookup::function_return_type>(subtree);
			bool block = mod.has_component<doir::block>(subtree);

			if(valueless) {
				// mod.get_or_add_component<doir::flags>(out).as_underlying() |= doir::flags::Valueless;
			} else if(number) {
				mod.add_component<doir::number>(out) = mod.get_component<doir::number>(subtree);
			} else if(string) {
				mod.add_component<doir::string>(out) = mod.get_component<doir::string>(subtree);
			} else if(call || call_lookup) {
				// Call == backlink
				if(mod.has_component<doir::call>(subtree)) {
					auto& destination = mod.add_component<doir::call>(out);
					auto& source = mod.get_component<doir::call>(subtree);
					destination.related[0] = subtitutions.contains(source.related[0]) ? subtitutions[source.related[0]] : source.related[0];
				}
				if(mod.has_component<doir::lookup::call>(subtree)) {
					auto& destination = mod.add_component<doir::lookup::call>(out);
					auto& lookup = mod.get_component<doir::lookup::call>(subtree);
					destination = lookup.resolved() && subtitutions.contains(lookup.entity())
						? doir::lookup::call{subtitutions[lookup.entity()]} : lookup;
				}

				// inputs == backlink
				if(mod.has_component<doir::function_inputs>(subtree)) {
					auto& destination = mod.add_component<doir::function_inputs>(out);
					auto& source = mod.get_component<doir::function_inputs>(subtree);
					destination.related.reserve(source.related.size());
					for(auto& e: source.related)
						destination.related.push_back(subtitutions.contains(e) ? subtitutions[e] : e);
				}
				if(mod.has_component<doir::lookup::function_inputs>(subtree)) {
					auto& destination = mod.add_component<doir::lookup::function_inputs>(out);
					auto& lookups = mod.get_component<doir::lookup::function_inputs>(subtree);
					destination.reserve(lookups.size());
					for(auto& lookup: lookups)
						destination.push_back(lookup.resolved() && subtitutions.contains(lookup.entity())
							? doir::lookup::type_of{subtitutions[lookup.entity()]} : lookup);
				}

				if(mod.has_component<doir::function_parameter_names>(subtree))
					mod.add_component<doir::function_parameter_names>(out) = mod.get_component<doir::function_parameter_names>(subtree);

			} else if(function_def || function_def_lookup) {
				// inputs == backlink
				if(mod.has_component<doir::function_inputs>(subtree)) {
					auto& destination = mod.add_component<doir::function_inputs>(out);
					auto& source = mod.get_component<doir::function_inputs>(subtree);
					destination.related.reserve(source.related.size());
					for(auto& e: source.related)
						destination.related.push_back(subtitutions.contains(e) ? subtitutions[e] : e);
				}
				if(mod.has_component<doir::lookup::type_of>(subtree)) {
					auto& destination = mod.add_component<doir::lookup::function_inputs>(out);
					auto& lookups = mod.get_component<doir::lookup::function_inputs>(subtree);
					destination.reserve(lookups.size());
					for(auto& lookup: lookups)
					destination.push_back(lookup.resolved() && subtitutions.contains(lookup.entity())
						? doir::lookup::type_of{subtitutions[lookup.entity()]} : lookup);
				}

				if(mod.has_component<doir::function_parameter_names>(subtree))
					mod.add_component<doir::function_parameter_names>(out) = mod.get_component<doir::function_parameter_names>(subtree);

				// return_type == backlink
				if(mod.has_component<doir::function_return_type>(subtree)) {
					auto& destination = mod.add_component<doir::function_return_type>(out);
					auto& source = mod.get_component<doir::function_return_type>(subtree);
					destination.related[0] = subtitutions.contains(source.related[0]) ? subtitutions[source.related[0]] : source.related[0];
				}
				if(mod.has_component<doir::lookup::function_return_type>(subtree)) {
					auto& destination = mod.add_component<doir::lookup::function_return_type>(out);
					auto& lookup = mod.get_component<doir::lookup::function_return_type>(subtree);
					destination = lookup.resolved() && subtitutions.contains(lookup.entity())
						? doir::lookup::function_return_type{subtitutions[lookup.entity()]} : lookup;
				}
			}

		} else if(mod.has_component<type_definition>(subtree)) {
			mod.add_component<type_definition>(out) = mod.get_component<type_definition>(subtree);

			if(mod.has_component<doir::function_inputs>(subtree) || mod.has_component<doir::lookup::function_inputs>(subtree)) { // TODO: Lookup function inputs?
				// inputs == backlink
				if(mod.has_component<doir::function_inputs>(subtree)) {
					auto& destination = mod.add_component<doir::function_inputs>(out);
					auto& source = mod.get_component<doir::function_inputs>(subtree);
					destination.related.reserve(source.related.size());
					for(auto& e: source.related)
						destination.related.push_back(subtitutions.contains(e) ? subtitutions[e] : e);
				}
				if(mod.has_component<doir::lookup::type_of>(subtree)) {
					auto& destination = mod.add_component<doir::lookup::function_inputs>(out);
					auto& lookups = mod.get_component<doir::lookup::function_inputs>(subtree);
					destination.reserve(lookups.size());
					for(auto& lookup: lookups)
					destination.push_back(lookup.resolved() && subtitutions.contains(lookup.entity())
						? doir::lookup::type_of{subtitutions[lookup.entity()]} : lookup);
				}

				// return_type == backlink
				if(mod.has_component<doir::function_return_type>(subtree)) {
					auto& destination = mod.add_component<doir::function_return_type>(out);
					auto& source = mod.get_component<doir::function_return_type>(subtree);
					destination.related[0] = subtitutions.contains(source.related[0]) ? subtitutions[source.related[0]] : source.related[0];
				}
				if(mod.has_component<doir::lookup::function_return_type>(subtree)) {
					auto& destination = mod.add_component<doir::lookup::function_return_type>(out);
					auto& lookup = mod.get_component<doir::lookup::function_return_type>(subtree);
					destination = lookup.resolved() && subtitutions.contains(lookup.entity())
						? doir::lookup::function_return_type{subtitutions[lookup.entity()]} : lookup;
				}
			}

		} else if(mod.has_component<doir::flags>(subtree) && mod.get_component<doir::flags>(subtree).namespace_set()) {
			// mod.add_component<doir::flags>(out).as_underlying() |= doir::flags::Namespace;
		} else if(mod.has_component<alias>(subtree) || mod.has_component<doir::lookup::alias>(subtree)) {
			// alias == backlink
			if(mod.has_component<doir::alias>(subtree)) {
				auto& destination = mod.add_component<doir::alias>(out);
				auto& source = mod.get_component<doir::alias>(subtree);
				destination.related[0] = subtitutions.contains(source.related[0]) ? subtitutions[source.related[0]] : source.related[0];
			}
			if(mod.has_component<doir::lookup::alias>(subtree)) {
				auto& destination = mod.add_component<doir::lookup::alias>(out);
				auto& lookup = mod.get_component<doir::lookup::alias>(subtree);
				destination = lookup.resolved() && subtitutions.contains(lookup.entity())
					? doir::lookup::alias{subtitutions[lookup.entity()]} : lookup;
			}
		}

		if(mod.has_component<doir::block>(subtree)) {
			for(auto& e: mod.get_component<doir::block>(out).related)
				deep_copy_copy_components(mod, e, out, subtitutions, reverse_subtitutions, extra_copy_instructions);
		}

		if(extra_copy_instructions)
			extra_copy_instructions(out, subtree);
	}

	ecrs::entity_t deep_copy_build_structure(module& mod, ecrs::entity_t subtree, std::unordered_map<ecrs::entity_t, ecrs::entity_t>& subtitutions, std::unordered_map<ecrs::entity_t, ecrs::entity_t>& reverse_subtitutions) {
		ecrs::entity_t out = mod.add_entity();
		assert(!subtitutions.contains(subtree));
		subtitutions[subtree] = out;
		reverse_subtitutions[out] = subtree;

		if(mod.has_component<doir::block>(subtree)) {
			auto& block = mod.add_component<doir::block>(out);
			auto& subtree_block = mod.get_component<doir::block>(subtree);
			block.related.reserve(subtree_block.related.size());
			for(auto& e: subtree_block.related)
				block.related.push_back(deep_copy_build_structure(mod, e, subtitutions, reverse_subtitutions));
		}

		return out;
	}

	ecrs::entity_t deep_copy(module& mod, ecrs::entity_t subtree, void(*extra_copy_instructions)(ecrs::entity_t dest, ecrs::entity_t src) /*= nullptr*/) {
		std::unordered_map<ecrs::entity_t, ecrs::entity_t> subtitutions;
		std::unordered_map<ecrs::entity_t, ecrs::entity_t> reverse_subtitutions;
		auto block = mod.get_component<doir::parent>(subtree).related[0];
		auto out = deep_copy_build_structure(mod, subtree, subtitutions, reverse_subtitutions);
		deep_copy_copy_components(mod, out, block, subtitutions, reverse_subtitutions, extra_copy_instructions);
		return out;
	}



	block_builder& block_builder::move_exisiting(block_builder& source) {
		assert(mod->has_component<doir::block>(block));
		assert(mod->has_component<doir::block>(source.block));
		auto& dest = mod->get_component<doir::block>(block);
		auto& src = mod->get_component<doir::block>(source.block);
		if(dest.related.empty())
			dest.related = std::move(src.related);
		else {
			std::copy(src.related.begin(), src.related.end(), std::back_inserter(dest.related));
			src.related.clear();
		}
		// Make sure they are labeled as having the new block as their parent
		for(auto e: dest.related)
			mod->get_or_add_component<doir::parent>(e).related = {block};
		return *this;
	}

	block_builder& block_builder::copy_existing(const block_builder& source, bool skip_parameters /*= false*/) {
		assert(mod->has_component<doir::block>(block));
		assert(mod->has_component<doir::block>(source.block));

		std::unordered_map<ecrs::entity_t, ecrs::entity_t> subtitutions, reverse_subtitutions;
		auto& block = mod->get_or_add_component<doir::block>(this->block);
		auto& source_related = mod->get_component<doir::block>(source.block).related;
		block.related.reserve(block.related.size() + source_related.size());

		size_t start = block.related.size();
		for(auto e: source_related) {
			if(skip_parameters && mod->has_component<doir::function_parameter>(e)) continue;
			block.related.push_back(deep_copy_build_structure(*mod, e, subtitutions, reverse_subtitutions));
		}
		for(size_t i = start; i < block.related.size(); ++i)
			deep_copy_copy_components(*mod, block.related[i], this->block, subtitutions, reverse_subtitutions, nullptr);

		return *this;
	}
}
