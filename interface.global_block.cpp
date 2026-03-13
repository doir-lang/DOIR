#define NOMINMAX
#define WIN32_LEAN_AND_MEAN

#include "interface.hpp"
#include "module.hpp"

namespace doir {
	block_builder& block_builder::build_global_block() {
		auto pointer_sized_interned = mod->interner.intern("pointer_sized");
		auto value_interned = mod->interner.intern("value");
		auto T_interned = mod->interner.intern("T");
		auto type = push_type(mod->interner.intern("type")).end();
		mod->get_or_add_component<doir::flags>(type).as_underlying() |= doir::flags::Comptime;

		auto compiler = push_namespace("compiler");
		std::vector<doir::lookup::lookup> inputs = {pointer_sized_interned, pointer_sized_interned};
		std::vector<interned_string> names = {mod->interner.intern("size_bits"), mod->interner.intern("align_bits")};
		auto base_type_t = compiler.push_function_type(mod->interner.intern("base_type_t"), inputs, type, names);
		mod->get_or_add_component<doir::flags>(base_type_t).as_underlying() |= doir::flags::Comptime;
		auto base_type = compiler.push_valueless_function(mod->interner.intern("base_type"), base_type_t);

		auto sixtyfour = compiler.push_number("_", pointer_sized_interned, 64);
		inputs = {sixtyfour, sixtyfour};
		auto pointer_sized = compiler.push_call(pointer_sized_interned, type, base_type, inputs);

		auto eight = compiler.push_number("_", pointer_sized, 8);
		inputs = {eight, eight};
		auto byte = compiler.push_call(mod->interner.intern("byte"), type, base_type, inputs);

		inputs = {byte};
		compiler.push_valueless_function(mod->interner.intern("emit"), compiler.push_function_type(mod->interner.intern("emit_t"), inputs, byte));

		inputs = {type, T_interned};
		names = {T_interned, value_interned};
		compiler.push_function(mod->interner.intern("return"), compiler.push_function_type(mod->interner.intern("return_t"), inputs, T_interned, names), true).end();
		return *this;
	}
}
