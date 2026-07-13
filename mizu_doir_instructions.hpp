#pragma once

#include "module.hpp"

#include <mizu/opcode.hpp>
#include <fp/string.h>

namespace mizu { inline namespace instructions { extern "C" {
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
}}}