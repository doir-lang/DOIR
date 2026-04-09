#include "../module.hpp"
#include "context.hpp"

namespace doir::canonicalize {
	thread_local extern ecrs::entity_t new_root;

	ecrs::entity_t sort(module& mod, ecrs::entity_t root);
}
