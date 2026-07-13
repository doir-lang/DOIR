#pragma once

#include "interface.hpp"
#include "module.hpp"
#include "libecrs/systems.hpp"
#include <deque>
#include <ranges>
#include <algorithm>

#include "print.hpp"
#include "sema/canonicalize/sort.hpp"

namespace doir::system {
	template<typename... Targs, std::invocable<ecrs::context&, ecrs::entity_t, Targs...> Tfunc>
	auto depth_first(ecrs::entity_t subtree, Tfunc&& func) {
		return [=](ecrs::context& ctx, Targs... args) -> bool {
			auto& mod = (doir::module&)ctx; // TODO: Verify cast

			struct Frame {
				ecrs::entity_t entity;
				std::size_t child_index;
			};
			std::vector<Frame> stack;
			stack.push_back({subtree == current_canonicalize_root ? canonicalize::new_root : subtree, 0});

			while(!stack.empty()) {
				auto& frame = stack.back();

				if(!mod.has_component<doir::block>(frame.entity)) {
					if(!func(mod, frame.entity, args...)) return false;
					stack.pop_back();
					continue;
				}

				auto& block = mod.get_component<doir::block>(frame.entity);
				if(frame.child_index < block.related.size()) {
					ecrs::entity_t child = block.related[frame.child_index];
					++frame.child_index;
					stack.push_back({child, 0}); // may invalidate `frame`, but it isn't used again this iteration
				} else {
					if(!func(mod, frame.entity, args...)) return false;
					stack.pop_back();
				}
			}

			return true;
		};
	}

	template<typename... Targs, std::invocable<ecrs::context&, ecrs::entity_t, Targs...> Tfunc>
	auto depth_first(Tfunc&& func) {
		return depth_first(doir::current_canonicalize_root, std::move(func));
	}

	template<typename... Targs, std::invocable<ecrs::context&, ecrs::entity_t, Targs...> Tfunc>
	auto breadth_first(ecrs::entity_t subtree, Tfunc&& func) {
		return [=](ecrs::context& ctx, Targs... args) -> bool {
			auto& mod = (doir::module&)ctx; // TODO: Verify cast

			std::deque<ecrs::entity_t> queue;
			queue.push_back(subtree == current_canonicalize_root ? canonicalize::new_root : subtree);

			while(!queue.empty()) {
				ecrs::entity_t entity = queue.front();
				queue.pop_front();

				if(!func(mod, entity, args...)) return false;

				if(!mod.has_component<doir::block>(entity)) continue;
				auto& block = mod.get_component<doir::block>(entity);
				for(auto e: block.related)
					queue.push_back(e);
			}

			return true;
		};
	}

	template<typename... Targs, std::invocable<ecrs::context&, ecrs::entity_t, Targs...> Tfunc>
	auto breadth_first(Tfunc&& func) {
		return breadth_first(doir::current_canonicalize_root, std::move(func));
	}
	
	template<typename... Targs, std::invocable<ecrs::context&, ecrs::entity_t, Targs...> Tfunc>
	auto sorted(ecrs::entity_t subtree, Tfunc&& func, bool independent = false, bool sort_when_finished = false) {
		return [=](ecrs::context& ctx, Targs... args) -> bool {
			constexpr static auto impl = [](const auto& impl, ecrs::entity_t subtree, bool independent, const Tfunc& func, doir::module& mod, Targs... args) {
				if(!mod.has_component<doir::block>(subtree))
					return func(mod, subtree, std::forward<Targs>(args)...);
				else {
					auto* block = &mod.get_component<doir::block>(subtree);
					if(block->related.empty())
						return func(mod, subtree, std::forward<Targs>(args)...);
#ifdef ECRS_PARALLEL_SYSTEMS
					else if (independent) {
						bool valid = true;
						auto range = std::ranges::views::iota(block->related[0], subtree + 1);
						std::for_each(std::execution::par_unseq, range.begin(), range.end(), [&](ecrs::entity_t e) {
							valid &= func(mod, e, std::forward<Targs>(args)...);
						});
						return valid;
					}
#endif
					else for(size_t e = block->related[0]; e <= subtree; ++e){
						// if(!block->related.size())
							block = &mod.get_component<doir::block>(subtree); // TODO: Why do we lose the block?
						if(e == block->related[0]) {
							if(!impl(impl, e, independent, func, mod, std::forward<Targs>(args)...)) // If the first child is a block its full range may not be captured by the loop!
								return false;
						} else if(!func(mod, e, std::forward<Targs>(args)...))
							return false;
					}
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

	bool& fixed_point_changed();

	template<typename Tsystem>
	auto fixed_point(Tsystem system) {
		return [=](ecrs::context& context, auto... args) -> bool {
			do {
				fixed_point_changed() = false;
				if(!system(context, args...)) return false;
			} while(fixed_point_changed());
			return true;
		};
	}
}

#define DOIR_MAKE_SORTED_WALKER(function, independent)\
	bool function(doir::module& mod, ecrs::entity_t subtree) {}
