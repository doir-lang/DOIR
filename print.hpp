#pragma once

#include "interface.hpp"
#include "module.hpp"
#include "sema/canonicalize/sort.hpp"
#include <ostream>

namespace doir {
	std::ostream& print(std::ostream& out, const module& mod, ecrs::entity_t root, bool pretty = true, bool debug = false);

	namespace system {
		inline auto print(std::ostream& out, ecrs::entity_t root = current_canonicalize_root, bool pretty = true, bool debug = true) {
			return [&out, root_ = root, pretty, debug](ecrs::context& ctx) -> bool {
				auto& mod = (doir::module&)ctx; // TODO: Verify cast
				auto root = root_;
				if(root == current_canonicalize_root) root = canonicalize::new_root;
				print(out, mod, root, pretty, debug);
				return true;
			};
		}
	}
}
