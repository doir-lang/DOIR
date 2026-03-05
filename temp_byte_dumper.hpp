#pragma once

#include "module.hpp"
#include "interface.hpp"
#include "string_helpers.hpp"
#include <unordered_map>

namespace doir {
	struct byte_dumper {
		std::vector<std::byte> values;

		std::vector<std::byte>& interpret_number_assign(std::vector<std::byte>& out, const doir::module& mod, ecrs::entity_t subtree) {
			if(!mod.has_component<doir::number>(subtree)) return out;

			size_t value = mod.get_component<doir::number>(subtree).value;
			if(values.size() <= subtree)
				values.resize(subtree * 2);
			values[subtree] = (std::byte)value;
			return out;
		}

		std::vector<std::byte>& interpret_call(std::vector<std::byte>& out, const doir::module& mod, ecrs::entity_t subtree) {
			if(!mod.has_component<doir::lookup::call>(subtree)) return out;

			auto& call = mod.get_component<doir::lookup::call>(subtree);
			auto inputs = mod.has_component<doir::function_inputs>(subtree)
				? doir::lookup::function_inputs::to_lookup(mod.get_component<doir::function_inputs>(subtree))
				: mod.get_component<doir::lookup::function_inputs>(subtree);
			assert(call.resolved());
			if(call.entity() == 9/* emit */) {
				assert(inputs[0].resolved());
				out.push_back(values[inputs[0].entity()]);
			}
			return out;
		}

		std::vector<std::byte> interpret(const doir::module& mod, ecrs::entity_t root) {
			assert(mod.has_component<doir::block>(root));
			auto& block = mod.get_component<doir::block>(root);

			std::vector<std::byte> out;
			for(auto e: block.related)
				interpret_call(interpret_number_assign(out, mod, e), mod, e);
			return out;
		}

	};
}
