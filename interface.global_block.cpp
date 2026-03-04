#define NOMINMAX
#define WIN32_LEAN_AND_MEAN

#include "interface.hpp"
#include "module.hpp"

namespace doir {
	block_builder& block_builder::build_global_block() {
		auto pointer_sized_interned = mod->interner.intern("pointer_sized");
		auto type_interned = mod->interner.intern("type");

		auto compiler = push_namespace("compiler");
		std::vector<doir::lookup::lookup> inputs = {pointer_sized_interned, pointer_sized_interned};
		auto base_type = compiler.push_valueless_function(mod->interner.intern("base_type"), compiler.push_function_type(mod->interner.intern("base_type_t"), inputs, type_interned));

		auto sixtyfour = compiler.push_number("_", pointer_sized_interned, 64);
		inputs = {sixtyfour, sixtyfour};
		auto pointer_sized = compiler.push_call(pointer_sized_interned, type_interned, base_type, inputs);

		auto eight = compiler.push_number("_", pointer_sized, 8);
		inputs = {eight, eight};
		auto byte = compiler.push_call(mod->interner.intern("byte"), type_interned, base_type, inputs);

		inputs = {byte};
		compiler.push_valueless_function(mod->interner.intern("emit"), compiler.push_function_type(mod->interner.intern("emit_t"), inputs, byte));
		return *this;
	}
}
