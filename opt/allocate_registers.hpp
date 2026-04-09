#pragma once

#include "../module.hpp"
#include "../interface.hpp"
#include "../systems.hpp"
#include "opt/compute_compiler_namespace.hpp"
#include "sema/lookup.hpp"
#include "storage.hpp"
#include <algorithm>

namespace doir::opt {
	inline bool allocate_registers(ecrs::context& ctx, ecrs::entity_t subtree) {
		static bool allocating = false;
		static size_t next_register = 0;

		auto& mod = (doir::module&)ctx; // TODO: Verify cast
		if(subtree < 5) {
			allocating = false;
			next_register = 1;
		}

		if(allocating) {
			static auto pin_register = doir::lookup::resolve(mod, mod.interner.intern("compiler.assembler.pin_register"), subtree);
			static auto register_ = doir::lookup::resolve(mod, mod.interner.intern("compiler.assembler.register"), subtree);

			if( !(mod.has_component<doir::number>(subtree) || mod.has_component<doir::string>(subtree) || mod.has_component<doir::call>(subtree)) ) return true;
			if(mod.has_component<assigned_register>(subtree)) return true;

			auto parent = find_parent(mod, subtree);
			auto& block = mod.get_component<doir::block>(parent);
			doir::block_builder builder{parent, &mod};

			// Pin the value to the next register
			auto type = mod.get_component<doir::type_of>(subtree).related[0];
			std::array<ecrs::entity_t, 3> inputs = {type, subtree, builder.push_number("_", register_, next_register++)};
			builder.push_call("_", register_, pin_register, inputs);
			// Move that pin from the end of the block to right after the value is created
			block.related.reserve(std::max(block.related.size() + 1, block.related.capacity())); // Make sure there is enough memory to perform the copies so that the iterator doesn't get invalidated
			auto it = std::find(block.related.begin(), block.related.end(), subtree) + 1;
			for(size_t i = 0; i < 2; ++i) {
				block.related.insert(it, block.related.back());
				block.related.pop_back();
			}

		} else {
			static auto begin_register_allocation = doir::lookup::resolve(mod, mod.interner.intern("compiler.assembler.begin_register_allocation"), subtree);
			if(!mod.has_component<doir::call>(subtree)) return true;

			auto func = mod.get_component<doir::call>(subtree).related[0];
			if(func == begin_register_allocation) allocating = true;
		}

		return true;
	}
}
