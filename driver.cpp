#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
// #define FP_DEFAULT_HASH_TABLE_BASE_SIZE 16

#define FP_IMPLEMENTATION
#define ECRS_IMPLEMENTATION
#include "module.hpp"
#include "file_manager.hpp"
#include "diagnostics.hpp"
#include "interface.hpp"
#include "parser.hpp"
#include "print.hpp"

#include "sema/canonicalize/sort.hpp"
#include "sema/lookup.hpp"
#include "sema/strip_names.hpp"
#include "sema/function_arity.hpp"
#include "sema/name_reuse.hpp"

#include "opt/inline_functions.hpp"
#include "opt/materialize_aliases.hpp"
#include "opt/compute_compiler_namespace.hpp"
#include "opt/mizu_materialize_immediates.hpp"
#include "opt/pin_registers.hpp"

#include "temp_byte_dumper.hpp"

#include <filesystem>
#include <iostream>
#include <fstream>

int main(int argc, char** argv) {
	if (argc != 2) {
		std::cout << "Usage: " << argv[0] << " <path to file to compile>" << std::endl;
		return 0;
	}

	doir::module mod;
	std::vector<doir::block_builder> builders;
	builders.push_back(doir::block_builder::create(mod).build_global_block());

	auto parser = initialize_parser(builders);

	mod.parse_file(parser, argv[1]);
	if(doir::diagnostics().count() > 0) {
		doir::diagnostics().print_all();
		if(doir::diagnostics().has_errors()) return -1;
	}

	auto root = builders.front().block;
	doir::verify::structure(doir::diagnostics(), mod, root);
	root = doir::canonicalize::sort(mod, root);
	// doir::print(std::cout, mod, root, true, true);

	using namespace std::placeholders;
	auto sema_schedule = ecrs::system::sequential(
		doir::system::sorted(doir::sema::validate::name_reuse),
		doir::system::sorted(doir::sema::resolve_lookups),
		doir::system::sorted(doir::sema::validate::lookups_resolved),
		ecrs::system::parallel(
			// doir::system::sorted(doir::sema::strip_names),
			doir::system::sorted(doir::sema::validate::function_arity, true)
		)
	);
	auto opt_schedule = ecrs::system::sequential(
		doir::system::sorted(doir::opt::pin_registers),
		doir::system::sorted(std::bind(doir::opt::compute_compiler_namespace, _1, _2, false)),
		doir::system::sorted(doir::opt::mizu::materialize_immediates, false, true),
		doir::system::sorted(doir::opt::inline_functions, false, true),
		doir::system::sorted(std::bind(doir::opt::compute_compiler_namespace, _1, _2, true))
		// doir::system::sorted(doir::system::bind_root(doir::opt::materialize_aliases))
	);

	sema_schedule(mod);
	opt_schedule(mod);
	// doir::print(std::cout, mod, doir::canonicalize::new_root, true, true);
	root = doir::canonicalize::sort(mod, doir::canonicalize::new_root);
	// doir::print(std::cout, mod, root, true, true);
	doir::verify::structure(doir::diagnostics(), mod, root);
	doir::print(std::cout, mod, root, true, true);

	{
		mod.interner.intern("compiler.emit"); mod.interner.intern("compiler.emit_bytes");
		auto bytes = doir::byte_dumper().interpret(mod, root);
		std::ofstream fout("res.bin", std::ios::binary);
		fout.write((char*)bytes.data(), bytes.size());
	}
}
