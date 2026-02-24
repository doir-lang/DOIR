#include "../module.hpp"

namespace doir::canonicalize {
	// void sort_tree_walk(module& mod, ecrs::entity_t subtree, std::vector<size_t>& order, std::set<ecrs::entity_t>& found);
	ecrs::entity_t sort(module& mod, ecrs::entity_t root);
}
