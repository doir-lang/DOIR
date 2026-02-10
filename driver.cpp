#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#define FP_DEFAULT_HASH_TABLE_BASE_SIZE 16

#define FP_IMPLEMENTATION
#define ECRS_IMPLEMENTATION
#include "module.hpp"
#include "file_manager.hpp"
#include "diagnostics.hpp"
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

	mod.parse_file(parser, argv[1]);
	if(doir::diagnostics().count() > 0) {
		doir::diagnostics().print_all();
		if(doir::diagnostics().has_errors()) return -1;
	}

	doir::print(std::cout, mod, builders.front().block, true, true);
}
