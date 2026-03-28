#define MIZU_IMPLEMENTATION
#define FP_OSTREAM_SUPPORT
#include <mizu/serialize.hpp>
#include <mizu/instructions.hpp>

#include <fp/string.hpp>

#include <iostream>
#include <cstddef>
#include <ostream>
#include <string_view>
#include <unordered_map>
#include <unordered_set>

const static mizu::opcode program[] = {
 // mizu::opcode{mizu::load_immediate, mizu::registers::t(0)}.set_immediate(40),
 mizu::opcode{mizu::add, 0, mizu::registers::t(0)},
 mizu::opcode{mizu::debug_print, 0, mizu::registers::t(0)},
 mizu::opcode{mizu::halt},
};

std::unordered_set<mizu::instruction_t> single_operand_ops = {mizu::debug_print};

size_t emit_byte(std::ostream& out, std::byte& byte) {
	static size_t id = 0;
	out << "\t%" << id << " : compiler.byte = " << (int)byte << "\n"
		<< "\t_ : compiler.byte = compiler.emit(%" << id << ")\n";
	return id++;
}

template<typename T>
std::ostream& emit(std::ostream& out, const T& v) {
	auto bytes = fp::view<const T>::from_variable(v).byte_view();
	std::unordered_map<std::byte, size_t> cache;
	for(auto byte : bytes)
		if(cache.contains(byte))
			out << "\t_ : compiler.byte = compiler.emit(%" << cache[byte] << ")\n";
		else cache[byte] = emit_byte(out, byte);
	return out;
}

int main() {
	auto num_opcodes = sizeof(program)/sizeof(program[0]);
	auto binary = mizu::to_binary({program, num_opcodes});
	auto portable = fp::view<mizu::serialization_opcode>((mizu::serialization_opcode*)binary.data(), num_opcodes);

	sizeof(mizu::serialization_opcode);

	std::cout << "_64 : compiler.pointer_sized = 64\n"
		<< "u64 : type = compiler.base_type(_64, _64)\n"
		<< "emit_register : (r : compiler.assembler.register) -> compiler.assembler.register = {\n"
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
		<< "\n"
		<< "load_immediate_op : (T : type) -> T = {\n";
	emit(std::cout, *mizu::lookup_id(mizu::load_immediate));
	std::cout << "\t_ : T = compiler.indicate_return(T)\n"
		<< "}\n"
		<< "load_upper_immediate_op : (T : type) -> T = {\n";
	emit(std::cout, *mizu::lookup_id(mizu::load_upper_immediate));
	std::cout << "\t_ : T = compiler.indicate_return(T)\n"
		<< "}\n" << std::endl;



	for(size_t i = 0; i < num_opcodes; ++i) {
		auto op = portable[i];
		auto name = *mizu::lookup_name(op.op);

		if(program[i].op == mizu::halt) {
			std::cout << name.data << " : () -> u64 = {\n";
			emit(std::cout, op.op);
			emit<uint64_t>(std::cout, 0);
			std::cout << "}\n" << std::endl;

		} else if(single_operand_ops.contains(program[i].op)) {
			std::cout << name.data << " : (a : u64, b : u64) -> u64 = {\n"
				<< "\trega : compiler.assembler.register = compiler.assembler.register_for(u64, a)\n"
				<< "\tregb : compiler.assembler.register = compiler.assembler.register_for(u64, b)\n"
				<< "\tregret : compiler.assembler.register = compiler.assembler.return_register(u64)\n";
			emit(std::cout, op.op);
			std::cout << "\t_ : compiler.assembler.register = inline emit_register(regret)\n"
				<< "\t_ : compiler.assembler.register = inline emit_register(rega)\n";
			emit<uint32_t>(std::cout, 0);
			std::cout << "\t_ : u64 = compiler.indicate_return(u64)\n"
				<< "}\n" << std::endl;

		} else {
			std::cout << name.data << " : (a : u64, b : u64) -> u64 = {\n"
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
	}
}
