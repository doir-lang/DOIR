#define NOMINMAX
#define WIN32_LEAN_AND_MEAN 

#include "module.hpp"
#include "file_manager.hpp"
#include "interface.hpp"
#include "parser.hpp"
#include "print.hpp"

#include <filesystem>
#include <iostream>

int main(int argc, char** argv) {
	if (argc != 2) {
		std::cout << "Usage: " << argv[0] << " <path to file to compile>" << std::endl;
		return 0;
	}
	
	doir::module mod;
	std::vector<doir::block_builder> builders;
	builders.push_back(doir::block_builder::create(mod));

	doir::string_interner interner;
	auto parser = initialize_parser(builders, interner);

	std::string_view test_file = argv[1];
	auto test = doir::file_manager::singleton().get_file_string(test_file);
	mod.source = test;
	if(!mod.parse(parser, test_file))
		return -1;

	doir::print(std::cout, mod, builders.front().block, true, false);
}
