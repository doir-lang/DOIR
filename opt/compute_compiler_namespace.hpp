#pragma once

#include "../module.hpp"
#include "../interface.hpp"

namespace doir::opt {
	bool compute_compiler_namespace(ecrs::context& ctx, ecrs::entity_t subtree);

	struct assigned_register {
		size_t reg;
	};
}
