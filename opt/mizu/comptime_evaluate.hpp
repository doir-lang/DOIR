#pragma once

#include "../../module.hpp"
#include "../../interface.hpp"

#include <functional>

namespace doir::opt::mizu {

	inline bool comptime_value_available(doir::module& mod, ecrs::entity_t subtree) {
		return mod.has_component<doir::number>(subtree) || mod.has_component<doir::string>(subtree) 
			|| mod.has_component<comptime_number>(subtree) || mod.has_component<comptime_string>(subtree);
	}

	bool comptime_evaluate(ecrs::context& ctx, ecrs::entity_t subtree, std::function<bool(ecrs::context&)> mizu_schedule);
}
