#pragma once

#include "interface.hpp"
#include "module.hpp"
#include "libecrs/systems.hpp"
#include <ranges>
#include <algorithm>

#include "print.hpp"
#include "sema/canonicalize/sort.hpp"

namespace doir::system {
	template<typename... Targs, std::invocable<ecrs::context&, ecrs::entity_t, Targs...> Tfunc>
	auto sorted(ecrs::entity_t subtree, Tfunc&& func, bool independent = false, bool sort_when_finished = false) {
		return [=](ecrs::context& ctx, Targs... args) -> bool {
			constexpr static auto impl = [](const auto& impl, ecrs::entity_t subtree, bool independent, const Tfunc& func, doir::module& mod, Targs... args) {
				if(!mod.has_component<doir::block>(subtree))
					return func(mod, subtree, std::forward<Targs>(args)...);
				else {
					auto& block = mod.get_component<doir::block>(subtree);
					if(block.related.empty())
						return func(mod, subtree, std::forward<Targs>(args)...);
#ifdef ECRS_PARALLEL_SYSTEMS
					else if (independent) {
						bool valid = true;
						auto range = std::ranges::views::iota(block.related[0], subtree + 1);
						std::for_each(std::execution::par_unseq, range.begin(), range.end(), [&](ecrs::entity_t e) {
							valid &= func(mod, e, std::forward<Targs>(args)...);
						});
						return valid;
					}
#endif
					else for(size_t e = block.related[0]; e <= subtree; ++e)
						if(e == block.related[0]) {
							if(!impl(impl, e, independent, func, mod, std::forward<Targs>(args)...)) // If the first child is a block its full range may not be captured by the loop!
								return false;
						} else if(!func(mod, e, std::forward<Targs>(args)...))
							return false;
				}
				return true;
			};

			auto& mod = (doir::module&)ctx; // TODO: Verify cast
			auto root = subtree;
			if(subtree == current_canonicalize_root) root = canonicalize::new_root;
			bool out = impl(impl, root, independent, func, mod, std::forward<Targs>(args)...);
			if(sort_when_finished) {
				// doir::print(std::cout, mod, root, true, true);
				root = canonicalize::sort(mod, root);
			}
			return out;
		};
	}

	template<typename... Targs, std::invocable<ecrs::context&, ecrs::entity_t, Targs...> Tfunc>
	auto sorted(Tfunc&& func, bool independent = false, bool sort_when_finished = false) {
		return sorted(doir::current_canonicalize_root, std::move(func), independent, sort_when_finished);
	}

	template<typename... Targs, std::invocable<ecrs::context&, ecrs::entity_t, ecrs::entity_t, Targs...> Tfunc>
	auto bind_root(Tfunc&& func) {
		using namespace std::placeholders;
		return std::bind(func, _1, _2, current_canonicalize_root);
	}
}

#define DOIR_MAKE_SORTED_WALKER(function, independent)\
	bool function(doir::module& mod, ecrs::entity_t subtree) {}
