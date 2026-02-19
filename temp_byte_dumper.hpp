#pragma once

#include "module.hpp"
#include "interface.hpp"
#include "string_helpers.hpp"
#include <unordered_map>

namespace doir {
	struct byte_dumper {
		const interned_string compiler_emit;
		fp::hash_map<interned_string, std::byte> lookup;

		byte_dumper(string_interner& interner) : compiler_emit(interner.intern("compiler.emit")) {}

		fp::raii::dynarray<std::byte>& interpret_number_assign(fp::raii::dynarray<std::byte>& out, const doir::module& mod, ecrs::entity_t root) {
			if(!mod.has_component<doir::name>(root)) return out;
			if(!mod.has_component<doir::number>(root)) return out;

			auto name = mod.get_component<doir::name>(root);
			auto dbg = mod.get_component<doir::number>(root).value;
			size_t value = dbg;
			lookup[name] = (std::byte)value;
			return out;
		}

		fp::raii::dynarray<std::byte>& interpret_call(fp::raii::dynarray<std::byte>& out, const doir::module& mod, ecrs::entity_t root) {
			if(!mod.has_component<doir::lookup::call>(root)) return out;

			auto& call = mod.get_component<doir::lookup::call>(root);
			auto inputs = mod.has_component<doir::function_inputs>(root)
				? doir::lookup::function_inputs::to_lookup(mod.get_component<doir::function_inputs>(root))
				: mod.get_component<doir::lookup::function_inputs>(root);
			assert(!call.resolved());
			if(call.name() == compiler_emit) {
				assert(!inputs[0].resolved());
				out.push_back(lookup[inputs[0].name()]);
			}
			return out;
		}

		fp::raii::dynarray<std::byte> interpret(const doir::module& mod, ecrs::entity_t root) {
			assert(mod.has_component<doir::block>(root));
			auto& block = mod.get_component<doir::block>(root);

			fp::raii::dynarray<std::byte> out;
			for(auto e: block.related)
				interpret_call(interpret_number_assign(out, mod, e), mod, e);
			return out;
		}

	};
}
