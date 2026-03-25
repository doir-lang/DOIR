#define NOMINMAX
#define WIN32_LEAN_AND_MEAN

#include "inline_functions.hpp"

#include "../module.hpp"
#include "../systems.hpp"
#include "../sema/lookup.hpp"

namespace doir::opt {
	bool inline_functions(ecrs::context& ctx, ecrs::entity_t subtree) {
		auto& mod = (doir::module&)ctx; // TODO: Verify cast
		if(!mod.has_component<doir::call>(subtree)) return true;

		auto call = mod.get_component<doir::call>(subtree);
		auto function_def = call.related[0]; // TODO: Resolve aliases
		auto ft = mod.get_component<doir::type_of>(function_def).related[0];
		if( !(mod.flags_set(ft, doir::flags::Inline) || mod.flags_set(subtree, doir::flags::Inline)) )
			return true;

		mod.remove_component<doir::call>(subtree);
		auto inputs = mod.get_component<doir::function_inputs>(subtree);
		mod.remove_component<doir::function_inputs>(subtree);

		auto params = inputs.associated_parameters(mod, mod.get_component<doir::block>(function_def));

		mod.add_component<doir::block>(subtree);
		doir::block_builder block = {subtree, &mod};

		std::unordered_map<ecrs::entity_t, ecrs::entity_t> param_replacements;
		for(size_t i = 0; i < inputs.related.size(); ++i) {
			auto name = mod.has_component<doir::name>(params[i])
				? mod.get_component<doir::name>(params[i])
				: mod.interner.intern("a" + std::to_string(i));
			param_replacements[params[i]] = block.push_alias(name, inputs.related[i]);
		}

		block.copy_existing({function_def, &mod}, true);
		mod.substitute_entities(subtree, param_replacements);

		auto indicate_return = lookup::resolve(mod, mod.interner.intern("compiler.indicate_return"), subtree);
		auto indicate_yield = lookup::resolve(mod, mod.interner.intern("compiler.indicate_yield"), subtree);
		auto return_register = lookup::resolve(mod, mod.interner.intern("compiler.assembler.return_register"), subtree);
		auto yield_register = lookup::resolve(mod, mod.interner.intern("compiler.assembler.yield_register"), subtree);
		mod.substitute_entities(subtree, {{indicate_return, indicate_yield}, {return_register, yield_register}}, 1); // TODO: Does this fix recursive issues?
		// TODO: Calls to return should become calls to yield

		mod.get_or_add_component<doir::flags>(subtree).as_underlying()
			= mod.flags_set(subtree, doir::flags::Export) * doir::flags::Export
			| mod.flags_set(subtree, doir::flags::Flatten) * doir::flags::Flatten;

		return true;
	}
}
