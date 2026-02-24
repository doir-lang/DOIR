#include <span>
#include "sort.hpp"

#include "../interface.hpp"
#include "storage.hpp"
#include <algorithm>
#include <iterator>
#include <numeric>
// #include <ostream>


namespace doir::canonicalize {
	void sort_tree_walk(module& mod, ecrs::entity_t subtree, std::vector<size_t>& order, std::set<ecrs::entity_t>& found) {
		if(found.contains(subtree))
			return;

		if(mod.has_component<doir::block>(subtree)) for(auto e: mod.get_component<doir::block>(subtree).related)
			sort_tree_walk(mod, e, order, found);

		if(mod.has_component<type_of>(subtree) || mod.has_component<lookup::type_of>(subtree)) {
			lookup::type_of t = mod.has_component<type_of>(subtree)
				? lookup::type_of(mod.get_component<type_of>(subtree).related[0])
				: mod.get_component<lookup::type_of>(subtree);

			if(t.resolved())
				sort_tree_walk(mod, t.entity(), order, found);

			bool valueless = mod.has_component<doir::flags>(subtree) && mod.get_component<doir::flags>(subtree).valueless_set();
			bool number = mod.has_component<doir::number>(subtree);
			bool string = mod.has_component<doir::string>(subtree);
			bool call = mod.has_component<doir::call>(subtree);
			bool call_lookup = mod.has_component<doir::lookup::call>(subtree);
			bool function_def = mod.has_component<doir::function_return_type>(subtree);
			bool function_def_lookup = mod.has_component<doir::lookup::function_return_type>(subtree);
			bool block = mod.has_component<doir::block>(subtree);

			if(call || call_lookup) {
				doir::lookup::lookup call = mod.has_component<doir::call>(subtree)
					? doir::lookup::lookup(mod.get_component<doir::call>(subtree).related[0])
					: doir::lookup::lookup(mod.get_component<doir::lookup::call>(subtree));
				if(call.resolved())
					sort_tree_walk(mod, call.entity(), order, found);
				auto inputs = mod.has_component<doir::function_inputs>(subtree)
					? doir::lookup::function_inputs::to_lookup(mod.get_component<doir::function_inputs>(subtree))
					: mod.get_component<doir::lookup::function_inputs>(subtree);
				for(auto& i: inputs)
					if(i.resolved())
						sort_tree_walk(mod, i.entity(), order, found);

			} else if(function_def || function_def_lookup) {
				sort_tree_walk(mod, t.entity(), order, found);
			}

		} else if(mod.has_component<type_definition>(subtree)) {
			if(mod.has_component<doir::function_inputs>(subtree)) {
				auto inputs = mod.has_component<doir::function_inputs>(subtree)
					? doir::lookup::function_inputs::to_lookup(mod.get_component<doir::function_inputs>(subtree))
					: mod.get_component<doir::lookup::function_inputs>(subtree);
				std::optional<doir::lookup::function_return_type> return_type = {};
				if(mod.has_component<doir::function_return_type>(subtree))
					return_type = {mod.get_component<doir::function_return_type>(subtree).related[0]};
				else if(mod.has_component<doir::lookup::function_return_type>(subtree))
					return_type = mod.get_component<doir::lookup::function_return_type>(subtree);

				if(return_type && return_type->resolved())
					sort_tree_walk(mod, return_type->entity(), order, found);
				for(auto& i: inputs)
					if(i.resolved())
						sort_tree_walk(mod, i.entity(), order, found);
			}

		} else if(mod.has_component<doir::flags>(subtree) && mod.get_component<doir::flags>(subtree).namespace_set()) {

		} else if(mod.has_component<alias>(subtree) || mod.has_component<doir::lookup::alias>(subtree)) {
			auto alias = mod.has_component<doir::alias>(subtree)
				? lookup::alias(mod.get_component<doir::alias>(subtree).related[0])
				: mod.get_component<lookup::alias>(subtree);

			if(alias.resolved())
				sort_tree_walk(mod, alias.entity(), order, found);
		}

		order.push_back(subtree);
		found.insert(subtree);
	}

	ecrs::entity_t sort(module& mod, ecrs::entity_t root) {
		std::vector<size_t> order = {0}; order.reserve(mod.entity_count());
		std::set<ecrs::entity_t> found = {0};
		sort_tree_walk(mod, root, order, found);
		assert(order.size() == found.size()); // If they aren't the same size there are duplicates in the order!

		std::set<ecrs::entity_t> all;
		{
			std::vector<ecrs::entity_t> _all; _all.resize(mod.entity_count());
			std::iota(_all.begin(), _all.end(), 0);
			all = {_all.begin(), _all.end()};
		}
		if(mod.freelist)
			for(auto e: mod.freelist)
				all.erase(e);

		std::set<ecrs::entity_t> missing;
		std::set_difference(all.begin(), all.end(), found.begin(), found.end(), std::inserter(missing, missing.begin()));

		// std::reverse(order.begin(), order.end()); // TODO: Postorder or Reverse Postorder
		assert(order.back() == root);
		auto new_root = order.size() - 1;
		std::copy(missing.begin(), missing.end(), std::back_inserter(order));

		// for(size_t i = 0; i < order.size(); ++i)
		// 	std::cout << order[i] << " -> " << i << std::endl;

		mod.reorder_entities<
			doir::block, doir::parent, doir::function_return_type, doir::function_inputs,
			doir::alias, doir::type_of, doir::call, doir::lookup::function_return_type,
			doir::lookup::function_inputs, doir::lookup::alias, doir::lookup::type_of, doir::lookup::call
		>({order});

		return new_root;
	}
}
