#pragma once

#include "interface.hpp"
#include "module.hpp"

#include <algorithm>
#include <mizu/opcode.hpp>
#include <fp/string.h>
#include <string>

namespace mizu { inline namespace instructions { extern "C" {
	constexpr static mizu::reg_t current_entity_reg = 2; // TODO: Needs to be kept in sync with the location in the comptime evaluation code

	inline void* doir_set_module(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp) {
		assert(sp == env->stack_bottom); // Set module is expected to be run at the start of the program

		sp -= sizeof(void*);
		assert(sp > env->stack_boundary);
		assert(sp <= env->stack_bottom);
		
		doir::module* mod = (doir::module*)registers[pc->a];
		*(doir::module**)env->stack_bottom = mod;
		registers[pc->out] = (size_t)mod;
		
		MIZU_NEXT();
	}
	MIZU_REGISTER_INSTRUCTION(doir_set_module);

	inline void* doir_attach_comptime_number_i64(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp) {
		auto mod = *(doir::module**)env->stack_bottom;
		auto e = (ecrs::entity_t)registers[pc->a];
		auto& out = mod->get_or_add_component<doir::comptime_number>(e);
		auto dbg = out.value = registers[pc->b];
		registers[pc->out] = (size_t)&out;	
		MIZU_NEXT();
	}
	MIZU_REGISTER_INSTRUCTION(doir_attach_comptime_number_i64);

	inline void* doir_execute(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp) {
		auto mod = *(doir::module**)env->stack_bottom;
		auto e = (ecrs::entity_t)registers[current_entity_reg];
		auto blk = (ecrs::entity_t)registers[pc->a];
		auto type = mod->get_component<doir::type_of>(e).related[0];

		auto copied = doir::deep_copy(*mod, blk);
		auto& copied_block = mod->get_component<doir::block>(copied);

		strip_value(*mod, e);
		doir::block_builder::attach_subblock(*mod, e, type);
		copied_block.inline_into(*mod, e, 0);
		
		auto dbg = registers[pc->out] = e;	
		MIZU_NEXT();
	}
	MIZU_REGISTER_INSTRUCTION(doir_execute);

		inline void* doir_execute_if(opcode* pc, uint64_t* registers, registers_and_stack* env, uint8_t* sp) {
		auto mod = *(doir::module**)env->stack_bottom;
		auto e = (ecrs::entity_t)registers[current_entity_reg];
		auto blk = (ecrs::entity_t)registers[pc->a];


		if(registers[pc->b]) {
			// If the condition is true we inline the block
			auto type = mod->get_component<doir::type_of>(e).related[0];

			auto copied = doir::deep_copy(*mod, blk);
			auto& copied_block = mod->get_component<doir::block>(copied);

			strip_value(*mod, e);
			doir::block_builder::attach_subblock(*mod, e, type);
			copied_block.inline_into(*mod, e, 0);
		} else {
			// Otherwise we erase this call from existence
			auto parent = find_parent(*mod, e);
			auto& parent_block = mod->get_component<doir::block>(parent);
			parent_block.related.erase(std::remove(parent_block.related.begin(), parent_block.related.end(), e), parent_block.related.end());
		}

		auto dbg = registers[pc->out] = e;	
		MIZU_NEXT();
	}
	MIZU_REGISTER_INSTRUCTION(doir_execute_if);
}}}