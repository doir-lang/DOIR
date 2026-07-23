#pragma once

#include "../../module.hpp"
#include "../../interface.hpp"

#include <functional>

namespace doir::opt::mizu {

	inline bool comptime_value_available(doir::module& mod, ecrs::entity_t subtree) {
		static auto type = doir::lookup::resolve(mod, "type", 1, true);
		static auto block_ = doir::lookup::resolve(mod, "block", 1, true);

		return mod.has_component<doir::number>(subtree) || mod.has_component<doir::string>(subtree) 
			|| mod.has_component<comptime_number>(subtree) || mod.has_component<comptime_string>(subtree)
			|| (mod.has_component<doir::type_of>(subtree) && (mod.get_component<doir::type_of>(subtree).related[0] == type || mod.get_component<doir::type_of>(subtree).related[0] == block_));
	}

	bool comptime_evaluate(ecrs::context& ctx, ecrs::entity_t subtree, std::function<bool(ecrs::context&)> mizu_schedule);
}
