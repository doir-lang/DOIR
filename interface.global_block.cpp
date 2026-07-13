#define NOMINMAX
#define WIN32_LEAN_AND_MEAN

#include "interface.hpp"
#include "module.hpp"
#include "sema/lookup.hpp"

namespace doir {
	ecrs::entity_t push_common(doir::module *mod, ecrs::entity_t block, interned_string name, bool append = true);

	block_builder& block_builder::build_builtin_block() {
		auto pointer_sized_interned = mod->interner->intern("pointer_sized");
		auto value_interned = mod->interner->intern("value");
		auto T_interned = mod->interner->intern("T");
		auto type = push_type(mod->interner->intern("type")).end();
		mod->get_component<doir::type_definition>(type).always_comptime = true;
		mod->get_or_add_component<doir::flags>(type).as_underlying() |= doir::flags::Comptime;

		push_type(mod->interner->intern("void")).end();
		auto early_include = push_common(mod, block, mod->interner->intern("early_include"));

		auto compiler = push_namespace("compiler");
		std::vector<doir::lookup::lookup> inputs = {pointer_sized_interned, pointer_sized_interned};
		std::vector<interned_string> names = {mod->interner->intern("size_bits"), mod->interner->intern("align_bits")};
		auto base_type_t = compiler.push_function_type(mod->interner->intern("base_type_t"), inputs, type, names);
		mod->get_or_add_component<doir::flags>(base_type_t).as_underlying() |= doir::flags::Comptime;
		auto base_type = compiler.push_valueless_function(mod->interner->intern("base_type"), base_type_t);
		auto comptime_base_type = compiler.push_valueless_function(mod->interner->intern("comptime_base_type"), base_type_t);

		auto sixtyfour = compiler.push_number("_", pointer_sized_interned, sizeof(size_t) * 8);
		inputs = {sixtyfour, sixtyfour};
		auto pointer_sized = compiler.push_call(pointer_sized_interned, type, base_type, inputs);

		auto eight = compiler.push_number("_", pointer_sized, 8);
		inputs = {eight, eight};
		auto byte = compiler.push_call(mod->interner->intern("byte"), type, base_type, inputs);
		auto byte_pointer = compiler.push_pointer(mod->interner->intern("byte_pointer"), byte);

		inputs = {byte_pointer};
		auto early_include_t = compiler.push_function_type(mod->interner->intern("early_include_t"), inputs, pointer_sized);
		mod->get_or_add_component<doir::flags>(early_include_t).as_underlying() |= doir::flags::Comptime;
		attach_valueless_function(*mod, early_include, early_include_t);

		compiler.push_number(mod->interner->intern("current_entity"), pointer_sized, 0);

		inputs = {byte};
		auto emit_t = compiler.push_function_type(mod->interner->intern("emit_t"), inputs, byte);
		mod->get_or_add_component<doir::flags>(emit_t).as_underlying() |= doir::flags::Comptime;
		compiler.push_valueless_function(mod->interner->intern("emit"), emit_t);
		inputs = {byte_pointer};
		auto emit_bytes_t = compiler.push_function_type(mod->interner->intern("emit_bytes_t"), inputs, byte);
		mod->get_or_add_component<doir::flags>(emit_bytes_t).as_underlying() |= doir::flags::Comptime;
		compiler.push_valueless_function(mod->interner->intern("emit_bytes"), emit_bytes_t);

		inputs = {pointer_sized, pointer_sized};
		names = {value_interned, mod->interner->intern("arg")};
		auto bitwise_t = compiler.push_function_type(mod->interner->intern("bitwise_t"), inputs, pointer_sized, names);
		mod->get_or_add_component<doir::flags>(bitwise_t).as_underlying() |= doir::flags::Comptime;
		compiler.push_valueless_function(mod->interner->intern("bitwise_and"), bitwise_t);
		compiler.push_valueless_function(mod->interner->intern("shift_right"), bitwise_t);

		inputs = {type};
		names = {T_interned};
		auto return_t = compiler.push_function_type(mod->interner->intern("return_t"), inputs, T_interned, names);
		compiler.push_function(mod->interner->intern("indicate_return"), return_t, true).end();
		compiler.push_function(mod->interner->intern("indicate_yield"), return_t, true).end();

		auto pointer_t = compiler.push_function_type(mod->interner->intern("pointer_t"), inputs, T_interned, names);
		mod->get_or_add_component<doir::flags>(pointer_t).as_underlying() |= doir::flags::Comptime;
		compiler.push_function(mod->interner->intern("pointer"), pointer_t, true).end();
		compiler.push_function(mod->interner->intern("always_inline"), pointer_t, true).end();
		compiler.push_function(mod->interner->intern("always_comptime"), pointer_t, true).end();

		inputs = {type, T_interned};
		names = {T_interned, value_interned};
		compiler.push_function(mod->interner->intern("debug_print"), compiler.push_function_type(mod->interner->intern("debug_print_t"), inputs, byte, names), true).end();

		auto assembler = compiler.push_namespace("assembler");
		inputs = {sixtyfour, sixtyfour};
		auto register_ = assembler.push_call(mod->interner->intern("register"), type, comptime_base_type, inputs);

		// inputs = {type, T_interned};
		// names = {T_interned, value_interned};
		auto register_for_t = assembler.push_function_type(mod->interner->intern("register_for_t"), inputs, register_, names);
		mod->get_or_add_component<doir::flags>(register_for_t).as_underlying() |= doir::flags::Comptime;
		assembler.push_function(mod->interner->intern("register_for"), register_for_t, true).end();

		inputs = {type};
		names = {"_"};
		auto return_register_t = assembler.push_function_type(mod->interner->intern("return_register_t"), inputs, register_, names);
		mod->get_or_add_component<doir::flags>(return_register_t).as_underlying() |= doir::flags::Comptime;
		assembler.push_function(mod->interner->intern("return_register"), return_register_t, true).end();
		assembler.push_function(mod->interner->intern("yield_register"), return_register_t, true).end();

		inputs = {type, T_interned, register_};
		names = {T_interned, value_interned, mod->interner->intern("register")};
		assembler.push_function(mod->interner->intern("pin_register"), assembler.push_function_type(mod->interner->intern("pin_register_t"), inputs, return_register_t, names), true).end();

		inputs = {};
		assembler.push_function(mod->interner->intern("begin_register_allocation"), assembler.push_function_type(mod->interner->intern("begin_register_allocation_t"), inputs, register_), true).end();

		return *this;
	}

	const std::unordered_set<ecrs::entity_t>& block_builder::get_type_modifiers(const doir::module& mod, ecrs::entity_t root){
		static std::unordered_set<ecrs::entity_t> modifiers = {
			lookup::resolve(mod, "compiler.pointer", root),
			lookup::resolve(mod, "compiler.always_inline", root),
			lookup::resolve(mod, "compiler.always_comptime", root)
		};
		return modifiers;
	}
}
