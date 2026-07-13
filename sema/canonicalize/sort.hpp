#pragma once

#include "../module.hpp"
#include "context.hpp"

namespace doir::canonicalize {
	thread_local extern ecrs::entity_t new_root;

	ecrs::entity_t sort(module& mod, ecrs::entity_t root);

	namespace system {
		inline auto sort(ecrs::entity_t root = current_canonicalize_root) {
			return [root](ecrs::context& ctx) -> bool {
				auto& mod = (doir::module&)ctx; // TODO: Verify cast
				doir::canonicalize::sort(mod, root == current_canonicalize_root ? canonicalize::new_root : root);
				return true;
			};
		}
	}
}
