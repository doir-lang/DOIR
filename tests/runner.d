/// `-betterC` has no built-in unittest runner, so this walks every module's
/// tests with `__traits(getUnitTests)` and calls them.
///
/// The tests live at the bottom of the source modules they cover, so this list
/// is a list of source modules; anything added to it is picked up automatically.
///
/// Progress goes to `stderr`, which is unbuffered, so a test that hangs or
/// aborts still leaves a record of how far the run got.
module tests.runner;

import core.stdc.stdio : fprintf, printf, stderr;

private enum modules = [
	"doir.string_helpers",
	"doir.print",
	"doir.file_manager",
	"doir.diagnostics",
	"doir.module_",
	"doir.interface_",
	"doir.systems",
	"doir.dynamic_systems",
	"doir.verify",
	"doir.parser",
	"doir.byte_emiter",
	"doir.pipeline",
	"doir.mizu.instructions",
	"doir.pipeline.sema.function_arity",
	"doir.pipeline.sema.strip_names",
	"doir.pipeline.sema.name_reuse",
	"doir.pipeline.canon.lookup",
	"doir.pipeline.canon.process_early_include",
	"doir.pipeline.canon.materialize",
	"doir.pipeline.canon.comptime",
	"doir.pipeline.canon.sort",
	"doir.pipeline.opt.materialize_aliases",
	"doir.pipeline.canon.strip_freestanding_blocks",
	"doir.pipeline.opt.pin_registers",
	"doir.pipeline.canon.override_fallback_schedule",
	"doir.pipeline.opt.run_schedule",
	"doir.pipeline.opt.mizu.comptime_evaluate",
	"doir.pipeline.opt.mizu.materialize_immediates",
	"doir.pipeline.opt.mizu.materialize_labels",
	"doir.pipeline.opt.inline_functions",
	"doir.pipeline.opt.compute_compiler_namespace",
];

private int runEveryTest() @nogc nothrow {
	size_t total = 0;

	static foreach (name; modules) {{
		alias mod = mixin("imported!\"" ~ name ~ "\"");
		alias tests = __traits(getUnitTests, mod);
		fprintf(stderr, "%s (%d tests)\n", name.ptr, cast(int) tests.length);
		static foreach (i, test; tests) {
			fprintf(stderr, "  [%d] ", cast(int) i);
			test();
			fprintf(stderr, "ok\n");
			++total;
		}
	}}

	printf("doir: all %d tests passed.\n", cast(int) total);
	return 0;
}

/// `tools/coverage.sh` builds this as ordinary D rather than `-betterC`,
/// because `-cov` registers its counters through druntime. That build needs
/// druntime's own `main` so the registration actually runs.
version(DoirCoverage) {
	/*
	 * druntime would otherwise run every `unittest` itself on the way to
	 * `main`, and `runEveryTest` then runs the same tests a second time.
	 * Replacing the tester with one that runs nothing (but still asks for
	 * `main`) leaves this build doing exactly what the `-betterC` one does.
	 */
	shared static this() {
		import core.runtime : Runtime, UnitTestResult;
		Runtime.extendedModuleUnitTester = () => UnitTestResult(0, 0, true, false);
	}

	int main() { return runEveryTest(); }
} else
	extern(C) int main() @nogc nothrow { return runEveryTest(); }
