#include <filesystem>
#include <iostream>

#include <peglib.h>
#include <string_view>

#include "libecrs/context.hpp"

#include "file_manager.hpp"
#include "interface.hpp"
#include "module.hpp"
#include "parser.hpp"
#include "print.hpp"
#include "string_helpers.hpp"

int main() {
	doir::module mod;
	std::vector<doir::block_builder> builders;
	builders.push_back(doir::block_builder::create(mod));

	doir::string_interner interner;
	auto parser = initialize_parser(builders, interner);

	// auto test = doir::file_manager::singleton().get_file_string("../standard.doir");
	auto test = doir::file_manager::singleton().get_file_string("../test.doir");
	mod.source = test;
	if(!mod.parse(parser, "../test.doir"))
		return -1;

	doir::print(std::cout, mod, builders.front().block, true, true);
}
