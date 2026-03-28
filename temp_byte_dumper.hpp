#pragma once

#include "module.hpp"
#include "interface.hpp"
#include "sema/lookup.hpp"
#include "string_helpers.hpp"
#include <unordered_map>

namespace doir {
	struct byte_dumper {
		std::vector<std::byte> values;

		std::vector<std::byte>& interpret_number_assign(std::vector<std::byte>& out, const doir::module& mod, ecrs::entity_t subtree) {
			if(!mod.has_component<doir::number>(subtree)) return out;

			static auto byte = lookup::resolve((doir::module&)mod, *mod.interner.find("compiler.byte"), subtree);
			if(mod.get_component<doir::type_of>(subtree).related[0] != byte) return out;

			size_t value = mod.get_component<doir::number>(subtree).value;
			if(values.size() <= subtree)
				values.resize(subtree * 2, (std::byte)0);
			values[subtree] = (std::byte)value;
			return out;
		}

		std::vector<std::byte>& interpret_call(std::vector<std::byte>& out, const doir::module& mod, ecrs::entity_t subtree) {
			if(!mod.has_component<doir::call>(subtree)) return out;
			if(doir::inside_function(mod, subtree)) return out;

			static auto emit = lookup::resolve((doir::module&)mod, *mod.interner.find("compiler.emit"), subtree);

			auto& call = mod.get_component<doir::call>(subtree);
			auto& inputs = mod.get_component<doir::function_inputs>(subtree);
			if(call.related[0] == emit)
				out.push_back(values.at(inputs.related[0]));
			return out;
		}

		std::vector<std::byte>& interpret_block(std::vector<std::byte>& out, const doir::module& mod, ecrs::entity_t subtree) {
			assert(mod.has_component<doir::block>(subtree));
			auto& block = mod.get_component<doir::block>(subtree);

			for(auto e: block.related)
				if(mod.has_component<doir::block>(e))
					interpret_block(out, mod, e);
				else interpret_call(interpret_number_assign(out, mod, e), mod, e);
			return out;
		}

		std::vector<std::byte> interpret(const doir::module& mod, ecrs::entity_t root) {
			std::vector<std::byte> out;
			return interpret_block(out, mod, root);
		}

	};
}
