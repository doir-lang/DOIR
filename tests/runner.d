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
	"doir.module_",
	"doir.interface_",
	"doir.systems",
	"doir.verify",
	"doir.parser",
	"doir.byte_dumper",
	"doir.pipeline.sema.function_arity",
	"doir.pipeline.opt.compute_compiler_namespace",
];

extern(C) int main() @nogc nothrow {
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
