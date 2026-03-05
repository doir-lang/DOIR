#pragma once

#include "../module.hpp"
#include <ranges>
#include <algorithm>
// #include <execution>

#define DOIR_MAKE_SORTED_WALKER(function, independent)\
	bool function(doir::module& mod, ecrs::entity_t subtree) {\
		if(!mod.has_component<doir::block>(subtree))\
			return function##_impl(mod, subtree);\
		else {\
			auto& block = mod.get_component<doir::block>(subtree);\
			if(block.related.empty())\
				return function##_impl(mod, subtree);\
			else /*if constexpr(independent) {\
				bool valid = true;\
				auto range = std::ranges::views::iota(block.related[0], subtree + 1);\
				std::for_each(std::execution::par_unseq, range.begin(), range.end(), [&](ecrs::entity_t e) {\
					valid &= function(mod, e);\
				});\
			} else*/ for(size_t e = block.related[0]; e <= subtree; ++e)\
				if(e == block.related[0]) {\
					if(!function(mod, e)) /* If the first child is a block its full range may not be captured by the loop!*/\
						return false;\
				} else if(!function##_impl(mod, e))\
					return false;\
		}\
		return true;\
	}
