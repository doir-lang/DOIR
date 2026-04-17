#define MIZU_IMPLEMENTATION
#define FP_OSTREAM_SUPPORT
#include <mizu/serialize.hpp>
#include <mizu/instructions.hpp>

#include <fp/string.hpp>

#include <iostream>
#include <iomanip>
#include <cstddef>
#include <ostream>
#include <string_view>
#include <unordered_map>
#include <unordered_set>

const static mizu::opcode program[] = {
	mizu::opcode{mizu::find_label},
	mizu::opcode{mizu::debug_print},
	mizu::opcode{mizu::debug_print_binary},
	mizu::opcode{mizu::halt},
	mizu::opcode{mizu::convert_to_u64},
	mizu::opcode{mizu::convert_to_u32},
	mizu::opcode{mizu::convert_to_u16},
	mizu::opcode{mizu::convert_to_u8},
	mizu::opcode{mizu::stack_load_u64},
	mizu::opcode{mizu::stack_store_u64},
	mizu::opcode{mizu::stack_load_u32},
	mizu::opcode{mizu::stack_store_u32},
	mizu::opcode{mizu::stack_load_u16},
	mizu::opcode{mizu::stack_store_u16},
	mizu::opcode{mizu::stack_load_u8},
	mizu::opcode{mizu::stack_store_u8},
	mizu::opcode{mizu::stack_push},
	mizu::opcode{mizu::stack_push_immediate},
	mizu::opcode{mizu::stack_pop},
	mizu::opcode{mizu::stack_pop_immediate},
	mizu::opcode{mizu::offset_of_stack_bottom},
	mizu::opcode{mizu::jump_relative},
	mizu::opcode{mizu::jump_relative_immediate},
	mizu::opcode{mizu::jump_to},
	mizu::opcode{mizu::branch_relative},
	mizu::opcode{mizu::branch_relative_immediate},
	mizu::opcode{mizu::branch_to},
	mizu::opcode{mizu::set_if_equal},
	mizu::opcode{mizu::set_if_not_equal},
	mizu::opcode{mizu::set_if_less},
	mizu::opcode{mizu::set_if_less_signed},
	mizu::opcode{mizu::set_if_greater_equal},
	mizu::opcode{mizu::set_if_greater_equal_signed},
	mizu::opcode{mizu::add},
	mizu::opcode{mizu::subtract},
	mizu::opcode{mizu::multiply},
	mizu::opcode{mizu::divide},
	mizu::opcode{mizu::modulus},
	mizu::opcode{mizu::shift_left},
	mizu::opcode{mizu::shift_right_logical},
	mizu::opcode{mizu::shift_right_arithmetic},
	mizu::opcode{mizu::bitwise_xor},
	mizu::opcode{mizu::bitwise_and},
	mizu::opcode{mizu::bitwise_or}
};

std::unordered_set<mizu::instruction_t> single_operand_ops = {mizu::debug_print, mizu::debug_print_binary, mizu::convert_to_u64, mizu::convert_to_u32, mizu::convert_to_u16, mizu::convert_to_u8, mizu::stack_load_u64, mizu::stack_load_u32, mizu::stack_load_u16, mizu::stack_load_u8, mizu::stack_push, mizu::stack_pop, mizu::offset_of_stack_bottom, mizu::jump_relative, mizu::jump_to};
std::unordered_set<mizu::instruction_t> immediate_ops = {mizu::stack_push_immediate, mizu::stack_pop_immediate, mizu::jump_relative_immediate};
std::unordered_set<mizu::instruction_t> branch_immediate_ops = {mizu::branch_relative_immediate};

static size_t id = 0;

size_t emit_byte(std::ostream& out, std::byte& byte) {
	out << "\t%" << id << " : compiler.byte = " << (int)byte << "\n"
		<< "\t_ : compiler.byte = compiler.emit(%" << id << ")\n";
	return id++;
}

size_t emit_bytes(std::ostream& out, fp::view<const std::byte> bytes) {
	out << "\t%" << id << " : compiler.byte_pointer = \"";
	for(auto b: bytes)
		out << "\\x" << std::hex << std::setfill('0') << std::setw(2) << (int)b << std::dec;
	out << "\"\n"
		<< "\t_ : compiler.byte = compiler.emit_bytes(%" << id << ")\n";
	return id++;
}

template<typename T>
std::ostream& emit(std::ostream& out, const T& v) {
	auto bytes = fp::view<const T>::from_variable(v).byte_view();
	emit_bytes(out, bytes);
	return out;
}

int main() {
	auto num_opcodes = sizeof(program)/sizeof(program[0]);
	auto binary = mizu::to_binary({program, num_opcodes});
	auto portable = fp::view<mizu::serialization_opcode>((mizu::serialization_opcode*)binary.data(), num_opcodes);

	std::cout << "_64 : compiler.pointer_sized = 64\n"
		<< "u64 : type = compiler.base_type(_64, _64)\n"
		<< "\n"
		<< "zero_parameters_t_no_inline : type = () -> u64\n"
		<< "zero_parameters_t : type = compiler.always_inline(zero_parameters_t_no_inline)\n"
		<< "one_parameters_t_no_inline : type = (a : u64) -> u64\n"
		<< "one_parameters_t : type = compiler.always_inline(one_parameters_t_no_inline)\n"
		<< "two_parameters_t_no_inline : type = (a : u64, b : u64) -> u64\n"
		<< "two_parameters_t : type = compiler.always_inline(two_parameters_t_no_inline)\n"
		<< "immediate_t_no_inline : type = (immediate: u64) -> u64\n"
		<< "immediate_t : type = compiler.always_inline(immediate_t_no_inline)\n"
		<< "branch_immediate_t_no_inline : type = (a: u64, immediate: u64) -> u64\n"
		<< "branch_immediate_t : type = compiler.always_inline(branch_immediate_t_no_inline)\n"
		<< "\n"
		<< "emit_register_t_no_inline : type = (r : compiler.assembler.register) -> compiler.assembler.register\n"
		<< "emit_register_t : type = compiler.always_inline(emit_register_t_no_inline)\n"
		<< "emit_register : emit_register_t = {\n"
		<< "\t%8 : compiler.pointer_sized = 8\n"
		<< "\tmask : compiler.pointer_sized = 0xFF\n"
		<< "\tshift : compiler.pointer_sized = compiler.shift_right(r, %8)\n"
		<< "\tlow : compiler.byte = compiler.bitwise_and(r, mask)\n"
		<< "\t_ : compiler.byte = compiler.emit(low)\n"
		<< "\thigh : compiler.byte = compiler.bitwise_and(shift, mask)\n"
		<< "\t_ : compiler.byte = compiler.emit(high)\n"
		<< "\t_ : compiler.assembler.register = compiler.indicate_return(compiler.assembler.register)\n"
		<< "}\n"
		<< "\n\n"
		<< "load_immediate : (T : type, v : T) -> T = {}\n"
		<< "load_upper_immediate : (T : type, v : T) -> T = {}\n"
		<< "label : () -> compiler.assembler.register = {}\n"
		<< "\n"
		<< "load_immediate_op : (T : type) -> void = {\n";
	emit(std::cout, *mizu::lookup_id(mizu::load_immediate));
	std::cout << "\t_ : T = compiler.indicate_return(T)\n"
		<< "}\n"
		<< "load_upper_immediate_op : (T : type) -> void = {\n";
	emit(std::cout, *mizu::lookup_id(mizu::load_upper_immediate));
	std::cout << "\t_ : T = compiler.indicate_return(T)\n"
		<< "}\n"
		<< "label_op : () -> void = {\n";
	emit(std::cout, *mizu::lookup_id(mizu::label));
	std::cout << "\t_ : void = compiler.indicate_return(void)\n"
		<< "}\n" << std::endl;


	for(size_t i = 0; i < num_opcodes; ++i) {
		auto op = portable[i];
		auto name = *mizu::lookup_name(op.op);

		if(program[i].op == mizu::find_label) {
			std::cout << name.data << "_t_no_inline : type = (label: compiler.assembler.register) -> u64\n"
				<< name.data << "_t : type = compiler.always_inline(" << name.data << "_t_no_inline)\n"
			 	<< name.data << " : " << name.data << "_t = {\n"
				<< "\tregret : compiler.assembler.register = compiler.assembler.return_register(u64)\n";
			emit(std::cout, op.op);
			std::cout << "\t_ : compiler.assembler.register = inline emit_register(regret)\n"
				<< "\tmask : compiler.pointer_sized = 0xFF\n"
				<< "\tlowest : compiler.byte = compiler.bitwise_and(label, mask)\n"
				<< "\t_ : compiler.byte = compiler.emit(lowest)\n"
				<< "\t%8 : compiler.pointer_sized = 8\n"
				<< "\tshift_8 : compiler.pointer_sized = compiler.shift_right(label, %8)\n"
				<< "\tlow : compiler.byte = compiler.bitwise_and(shift_8, mask)\n"
				<< "\t_ : compiler.byte = compiler.emit(low)\n"
				<< "\t%16 : compiler.pointer_sized = 16\n"
				<< "\tshift_16 : compiler.pointer_sized = compiler.shift_right(label, %16)\n"
				<< "\thigh : compiler.byte = compiler.bitwise_and(shift_16, mask)\n"
				<< "\t_ : compiler.byte = compiler.emit(high)\n"
				<< "\t%24 : compiler.pointer_sized = 24\n"
				<< "\tshift_24 : compiler.pointer_sized = compiler.shift_right(label, %24)\n"
				<< "\thighest : compiler.byte = compiler.bitwise_and(shift_24, mask)\n"
				<< "\t_ : compiler.byte = compiler.emit(highest)\n";
			emit<uint16_t>(std::cout, 0);
			std::cout << "\t_ : u64 = compiler.indicate_return(u64)\n"
				<< "}\n" << std::endl;

		} else if(program[i].op == mizu::halt) {
			std::cout << name.data << " : zero_parameters_t = {\n";
			emit(std::cout, op.op);
			emit<uint64_t>(std::cout, 0);
			std::cout << "}\n" << std::endl;

		} else if(immediate_ops.contains(program[i].op)) {
			std::cout << name.data << " : immediate_t = {\n"
				<< "\tregret : compiler.assembler.register = compiler.assembler.return_register(u64)\n";
			emit(std::cout, op.op);
			std::cout << "\t_ : compiler.assembler.register = inline emit_register(regret)\n"
				<< "\tmask : compiler.pointer_sized = 0xFF\n"
				<< "\tlowest : compiler.byte = compiler.bitwise_and(label, mask)\n"
				<< "\t_ : compiler.byte = compiler.emit(lowest)\n"
				<< "\t%8 : compiler.pointer_sized = 8\n"
				<< "\tshift_8 : compiler.pointer_sized = compiler.shift_right(label, %8)\n"
				<< "\tlow : compiler.byte = compiler.bitwise_and(shift_8, mask)\n"
				<< "\t_ : compiler.byte = compiler.emit(low)\n"
				<< "\t%16 : compiler.pointer_sized = 16\n"
				<< "\tshift_16 : compiler.pointer_sized = compiler.shift_right(label, %16)\n"
				<< "\thigh : compiler.byte = compiler.bitwise_and(shift_16, mask)\n"
				<< "\t_ : compiler.byte = compiler.emit(high)\n"
				<< "\t%24 : compiler.pointer_sized = 24\n"
				<< "\tshift_24 : compiler.pointer_sized = compiler.shift_right(label, %24)\n"
				<< "\thighest : compiler.byte = compiler.bitwise_and(shift_24, mask)\n"
				<< "\t_ : compiler.byte = compiler.emit(highest)\n";
			emit<uint16_t>(std::cout, 0);
			std::cout << "\t_ : u64 = compiler.indicate_return(u64)\n"
				<< "}\n" << std::endl;

		} else if(branch_immediate_ops.contains(program[i].op)) {
			std::cout << name.data << " : branch_immediate_t = {\n"
				<< "\trega : compiler.assembler.register = compiler.assembler.register_for(u64, a)\n"
				<< "\tregret : compiler.assembler.register = compiler.assembler.return_register(u64)\n";
			emit(std::cout, op.op);
			std::cout << "\t_ : compiler.assembler.register = inline emit_register(regret)\n"
				<< "\t_ : compiler.assembler.register = inline emit_register(rega)\n"
				<< "\tmask : compiler.pointer_sized = 0xFF\n"
				<< "\tlow : compiler.byte = compiler.bitwise_and(label, mask)\n"
				<< "\t_ : compiler.byte = compiler.emit(low)\n"
				<< "\t%8 : compiler.pointer_sized = 8\n"
				<< "\tshift_8 : compiler.pointer_sized = compiler.shift_right(label, %8)\n"
				<< "\thigh : compiler.byte = compiler.bitwise_and(shift_8, mask)\n"
				<< "\t_ : compiler.byte = compiler.emit(high)\n";
			emit<uint16_t>(std::cout, 0);
			std::cout << "\t_ : u64 = compiler.indicate_return(u64)\n"
				<< "}\n" << std::endl;

		} else if(single_operand_ops.contains(program[i].op)) {
			std::cout << name.data << " : one_parameters_t = {\n"
				<< "\trega : compiler.assembler.register = compiler.assembler.register_for(u64, a)\n"
				<< "\tregret : compiler.assembler.register = compiler.assembler.return_register(u64)\n";
			emit(std::cout, op.op);
			std::cout << "\t_ : compiler.assembler.register = inline emit_register(regret)\n"
				<< "\t_ : compiler.assembler.register = inline emit_register(rega)\n";
			emit<uint32_t>(std::cout, 0);
			std::cout << "\t_ : u64 = compiler.indicate_return(u64)\n"
				<< "}\n" << std::endl;

		} else {
			std::cout << name.data << " : two_parameters_t = {\n"
				<< "\trega : compiler.assembler.register = compiler.assembler.register_for(u64, a)\n"
				<< "\tregb : compiler.assembler.register = compiler.assembler.register_for(u64, b)\n"
				<< "\tregret : compiler.assembler.register = compiler.assembler.return_register(u64)\n";
			emit(std::cout, op.op);
			std::cout << "\t_ : compiler.assembler.register = inline emit_register(regret)\n"
				<< "\t_ : compiler.assembler.register = inline emit_register(rega)\n"
				<< "\t_ : compiler.assembler.register = inline emit_register(regb)\n";
			emit<uint16_t>(std::cout, 0);
			std::cout << "\t_ : u64 = compiler.indicate_return(u64)\n"
				<< "}\n" << std::endl;
		}

		std::cout << "\n_ : u64 = compiler.assembler.begin_register_allocation()\n" << std::endl;
	}
}
