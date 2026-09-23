/// The `doir` compiler driver. Ported from driver.cpp.
///
/// The pass schedules themselves live in `doir.pipeline`, which the tests
/// drive too, so both run the same compile.
module main;

import core.stdc.stdio : FILE, fclose, fopen, fwrite, printf, stdout;

import ecrs.storage : invalidEntity;

static import fp.dynarray;

import doir.byte_emiter;
import doir.diagnostics;
import doir.interface_;
import doir.module_;
import doir.parser;
import doir.pipeline;
import doir.print;
import doir.pipeline.canon.sort : newRoot;

@nogc nothrow:


/// The driver's stage hook: print whatever the stage raised, and stop if any
/// of it was an error.
private bool reportDiagnostics() {
	if (diagnostics().count() > 0) {
		diagnostics().printAll();
		if (diagnostics().hasErrors()) return false;
	}
	return true;
}

extern(C) int main(int argc, char** argv) @trusted {
	import core.stdc.string : strlen;

	if (argc != 2) {
		printf("Usage: %s <path to file to compile>\n", argv[0]);
		return 0;
	}

	auto mod = createModule();
	scope(exit) freeModule(mod);
	auto builders = createBuilderStack(mod);
	scope(exit) fp.dynarray.free(builders);

	auto path = argv[1][0 .. strlen(argv[1])];
	parseFile(mod, builders, path);
	if (!reportDiagnostics()) return -1;

	auto root = runPipeline(mod, builders, &reportDiagnostics);
	if (root == invalidEntity) return -1;

	printModule(stdout, mod, root, true, true);

	{
		internIn(mod, "compiler.emit");
		internIn(mod, "compiler.emit_bytes");

		auto bytes = emitAll(mod, newRoot);
		scope(exit) fp.dynarray.free(bytes);

		FILE* fout = fopen("res.bin", "wb");
		if (fout !is null) {
			if (fp.dynarray.length(bytes)) fwrite(bytes, 1, fp.dynarray.length(bytes), fout);
			fclose(fout);
		}
	}

	return 0;
}
