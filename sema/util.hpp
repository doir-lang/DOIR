#pragma once

#include "../interface.hpp"
#include "../module.hpp"
#include "../libecrs/systems.hpp"
#include <ranges>
#include <algorithm>

namespace doir::system {
	template<typename... Targs, std::invocable<ecrs::context&, ecrs::entity_t, Targs...> Tfunc>
	auto sorted(ecrs::entity_t subtree, Tfunc&& func, bool independent = false) {
		return [=](ecrs::context& context, Targs... args) -> bool {
			constexpr static auto impl = [](const auto& impl, ecrs::entity_t subtree, bool independent, Tfunc&& func, ecrs::context& context, Targs... args) {
				if(!context.has_component<doir::block>(subtree))
					return func(context, subtree, std::forward<Targs>(args)...);
				else {
					auto& block = context.get_component<doir::block>(subtree);
					if(block.related.empty())
						return func(context, subtree, std::forward<Targs>(args)...);
#ifdef ECRS_PARALLEL_SYSTEMS
					else if (independent) {
						bool valid = true;
						auto range = std::ranges::views::iota(block.related[0], subtree + 1);
						std::for_each(std::execution::par_unseq, range.begin(), range.end(), [&](ecrs::entity_t e) {
							valid &= func(context, e, std::forward<Targs>(args)...);
						});
						return valid;
					}
#endif
					else for(size_t e = block.related[0]; e <= subtree; ++e)
						if(e == block.related[0]) {
							if(!impl(impl, e, independent, func, context, std::forward<Targs>(args)...)) // If the first child is a block its full range may not be captured by the loop!
								return false;
						} else if(!func(context, e, std::forward<Targs>(args)...))
							return false;
				}
				return true;
			};

			return impl(impl, subtree, independent, func, context, std::forward<Targs>(args)...);
		};
	}
}

#define DOIR_MAKE_SORTED_WALKER(function, independent)\
	bool function(doir::module& mod, ecrs::entity_t subtree) {}
