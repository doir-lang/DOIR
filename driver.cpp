#include <filesystem>
#include <iostream>

#include <peglib.h>
#include <string_view>

#include "file_manager.hpp"

int main() {
	peg::parser parser;

	parser.set_logger([](size_t line, size_t col, const std::string& msg, const std::string &rule) {
		std::cerr << line << ":" << col << ": " << msg << std::endl;
	});

	auto grammar =
#include "grammar.peg"
	;
	auto ok = parser.load_grammar(grammar);
	assert(ok);

	auto test = file_manager::singleton().get_file_string("../standard.doir");

	parser.enable_ast();

	std::shared_ptr<peg::Ast> ast;
	if (parser.parse(test, ast)) {
		// ast = parser.optimize_ast(ast);
		std::cout << peg::ast_to_s(ast) << std::endl;
	}
}
