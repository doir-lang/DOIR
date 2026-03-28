#define MIZU_IMPLEMENTATION
#define FP_OSTREAM_SUPPORT
#include <mizu/portable_format.hpp>
#include <mizu/instructions.hpp>

#include <fp/string.hpp>

#include <fstream>
#include <vector>
#include <cstddef>
#include <iostream>

int main() {
    std::ifstream fin("res.bin", std::ios::binary | std::ios::in);
    if (!fin) throw std::runtime_error("Failed to open file");

    fin.seekg(0, std::ios::end);
    std::size_t size = fin.tellg();
    fin.seekg(0, std::ios::beg);

    std::vector<std::byte> buffer(size);
    fin.read(reinterpret_cast<char*>(buffer.data()), size);

    if (!fin) throw std::runtime_error("Failed to read file");


    auto program = mizu::from_binary(fp::view<const std::byte>(buffer.data(), buffer.size()));

    mizu::registers_and_stack env = {};
    std::cout << mizu::portable::generate_header_file(program.full_view(), env) << std::endl;

    return 0;
}
