#include "comptime_evaluate.hpp"

#include "../../temp_byte_dumper.hpp"
#include "../../systems.hpp"
#include "opt/compute_compiler_namespace.hpp"

#define MIZU_IMPLEMENTATION
#include <mizu/portable_format.hpp>
#include <mizu/instructions.hpp>
#include "../../mizu_doir_instructions.hpp"


#include <stdexcept>

namespace doir::opt::mizu {
	bool comptime_evaluate(ecrs::context& ctx, ecrs::entity_t subtree, std::function<bool(ecrs::context&)> mizu_schedule) {
		auto& mod = (doir::module&)ctx; // TODO: Verify cast
		if(!mod.has_component<doir::call>(subtree)) return true;
		if(!mod.flags_set(subtree, doir::flags::Comptime)) return true;

		if(mod.has_component<doir::function_inputs>(subtree)) {
			auto& inputs = mod.get_component<doir::function_inputs>(subtree);
			for(auto e : inputs.related)
				if(!comptime_value_available(mod, e)) return true;
		}

		static ecrs::entity_t compiler = doir::lookup::resolve(mod, "compiler", 1, true);
		static ecrs::entity_t assembler = doir::lookup::resolve(mod, "compiler.assembler", 1, true);
		auto called_function = mod.get_component<doir::call>(subtree).related[0];
		auto parent = doir::find_parent(mod, called_function);
		if(parent == compiler || parent == assembler) return true; // Compiler functions have their own pass and shouldn't really be used outside of the mizu backend
		
		static ecrs::entity_t type = doir::lookup::resolve(mod, "type", 1, true);
		static ecrs::entity_t void_ = doir::lookup::resolve(mod, "void", 1, true);
		static ecrs::entity_t early_include = doir::lookup::resolve(mod, "early_include", 1, true);

		static ecrs::entity_t compiler_current_entity = doir::lookup::resolve(mod, "compiler.current_entity", 1, true);
		static ecrs::entity_t compiler_emit = doir::lookup::resolve(mod, "compiler.emit", 1, true);
		static ecrs::entity_t compiler_emit_bytes = doir::lookup::resolve(mod, "compiler.emit_bytes", 1, true);
		static ecrs::entity_t assembler_pin_register = doir::lookup::resolve(mod, "compiler.assembler.pin_register", 1, true);
		static ecrs::entity_t assembler_register = doir::lookup::resolve(mod, "compiler.assembler.register", 1, true);
		static ecrs::entity_t assembler_begin_register_allocation = doir::lookup::resolve(mod, "compiler.assembler.begin_register_allocation", 1, true);
		
		static ecrs::entity_t mizu = doir::lookup::resolve(mod, "mizu", 1, true);
		static ecrs::entity_t mizu_u64 = doir::lookup::resolve(mod, "mizu.u64", 1, true);
		static ecrs::entity_t mizu_halt = doir::lookup::resolve(mod, "mizu.halt", 1, true);
		static ecrs::entity_t mizu_load_immediate = doir::lookup::resolve(mod, "mizu.load_immediate", 1, true);
		static ecrs::entity_t mizu_load_upper_immediate = doir::lookup::resolve(mod, "mizu.load_upper_immediate", 1, true);
		static ecrs::entity_t mizu_doir_set_module = doir::lookup::resolve(mod, "mizu.doir_set_module", 1, true);
		static ecrs::entity_t mizu_doir_attach_comptime_number_i64 = doir::lookup::resolve(mod, "mizu.doir_attach_comptime_number", 1, true);
		
		if(called_function == mizu_halt) return true;

		mod.get_component<doir::number>(compiler_current_entity).value = subtree;

		doir::system::fixed_point_changed() = true;

		block_builder comptime_block = block_builder::create(mod);
		auto& block = mod.get_component<doir::block>(comptime_block.block).related;
		block.push_back(type);
		block.push_back(void_);
		block.push_back(early_include);
		block.push_back(compiler);
		block.push_back(mizu);

		auto mod_ptr = (size_t)&mod;
		auto current_module = comptime_block.push_number("_", mizu_u64, (uint32_t)mod_ptr);
		auto r_value = 1;
		auto r = comptime_block.push_number("_", assembler_register, r_value++); // two since the allocator tends to skip 2
		{
			std::array<ecrs::entity_t, 3> inputs = {mizu_u64, current_module, r};
			comptime_block.push_call("_", assembler_register, assembler_pin_register, inputs);	
		}
		{
			std::array<ecrs::entity_t, 2> inputs = {mizu_u64, current_module};
			comptime_block.push_call("_", assembler_register, mizu_load_immediate, inputs);
		}
		current_module = comptime_block.push_number("_", mizu_u64, (uint32_t)(mod_ptr >> 32));
		{
			std::array<ecrs::entity_t, 3> inputs = {mizu_u64, current_module, r};
			comptime_block.push_call("_", assembler_register, assembler_pin_register, inputs);	
		}
		{
			std::array<ecrs::entity_t, 2> inputs = {mizu_u64, current_module};
			comptime_block.push_call("_", assembler_register, mizu_load_upper_immediate, inputs);
		}
		{
			std::array<ecrs::entity_t, 1> inputs = {current_module};
			comptime_block.push_call("_", assembler_register, mizu_doir_set_module, inputs);
		}
		// comptime_block.push_call("_", assembler_register, assembler_begin_register_allocation, std::span<ecrs::entity_t>{});

		std::vector<ecrs::entity_t> arguments;
		size_t i = 0;
		if(mod.has_component<doir::function_inputs>(subtree)) {
			auto& inputs = mod.get_component<doir::function_inputs>(subtree);
			arguments.reserve(inputs.related.size());
			for(i = 0; i < inputs.related.size(); ++i) {
				auto e = inputs.related[i];
				auto name = mod.has_component<doir::name>(e) ? mod.get_component<doir::name>(e) : mod.interner->intern("a" + std::to_string(i));
				if(mod.has_component<doir::number>(e)) 
					e = comptime_block.push_number(name, mizu_u64, (size_t)mod.get_component<doir::number>(e).value);
				else if(mod.has_component<comptime_number>(e)) 
					e = comptime_block.push_number(name, mizu_u64, (size_t)mod.get_component<comptime_number>(e).value);
				else if(mod.has_component<doir::string>(e))
					e = comptime_block.push_number(name, mizu_u64, (size_t)mod.get_component<doir::string>(e).value.data());
				else if(mod.has_component<comptime_string>(e))
					e = comptime_block.push_number(name, mizu_u64, (size_t)mod.get_component<comptime_string>(e).value.data());
				else throw std::runtime_error("Comptime evaluation of call with non-comptime parameter");
				
				{
					std::array<ecrs::entity_t, 2> inputs = {mizu_u64, e};
					comptime_block.push_call("_", assembler_register, mizu_load_immediate, inputs);
				}
				r = comptime_block.push_number("_", assembler_register, r_value++);
				{
					std::array<ecrs::entity_t, 3> inputs = {mizu_u64, e, r};
					comptime_block.push_call("_", assembler_register, assembler_pin_register, inputs);
				}
				arguments.push_back(e);
			}
		}

		auto type_of = doir::alias::resolve(mod, mod.get_component<doir::type_of>(subtree).related[0]);
		auto ret = comptime_block.push_call(mod.get_component<doir::name>(subtree), type_of, called_function, arguments);
		r = comptime_block.push_number("_", assembler_register, r_value++);
		{
			std::array<ecrs::entity_t, 3> inputs = {mizu_u64, ret, r};
			comptime_block.push_call("_", assembler_register, assembler_pin_register, inputs);
		}

		if(true) { // type == number
			auto current_entity = comptime_block.push_number("_", mizu_u64, subtree);
			r = comptime_block.push_number("_", assembler_register, r_value++);
			{
				std::array<ecrs::entity_t, 2> inputs = {mizu_u64, current_entity};
				comptime_block.push_call("_", assembler_register, mizu_load_immediate, inputs);
			}
			{
				std::array<ecrs::entity_t, 3> inputs = {mizu_u64, current_entity, r};
				comptime_block.push_call("_", assembler_register, assembler_pin_register, inputs);
			}

			{
				std::array<ecrs::entity_t, 2> inputs = {current_entity, ret};
				comptime_block.push_call("_", mizu_u64, mizu_doir_attach_comptime_number_i64, inputs);
			}

		} // TODO: Store back string
	
		comptime_block.push_call("_", mizu_u64, mizu_halt, std::span<ecrs::entity_t>{});

		std::cout << "Comptime evaluating: " << subtree << std::endl;

		auto backup = doir::canonicalize::new_root;
		doir::canonicalize::new_root = comptime_block.block;
		// doir::print(std::cout, mod, comptime_block.block, true, true);
		mizu_schedule(mod);
		// doir::print(std::cout, mod, comptime_block.block, true, true);
		doir::canonicalize::new_root = backup;
		auto bytes = doir::byte_dumper().interpret(mod, comptime_block.block);

		auto dbg = &mod;
		{
			auto [program, env] = ::mizu::from_portable({bytes.data(), bytes.size()});
			::mizu::setup_environment(env, program.begin(), program.end());

			// std::cout << ::mizu::portable::generate_header_file(program.full_view(), env).auto_free().data() << std::endl;
			MIZU_START_FROM_ENVIRONMENT(program.data(), env);
		}

		return true;
	}
}
