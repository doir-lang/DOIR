#define DOIR_NO_PROFILING
#define DOIR_IMPLEMENTATION
#define FP_IMPLEMENTATION
#include "../src/ECS/ecs.h"

#include "../src/ECS/relational.hpp"

#include <nowide/iostream.hpp>
#include <nanobench.h>

int main() {
	ankerl::nanobench::Bench().minEpochIterations(10000).run("doir::kanren::TypeCheck", []{
		system("./bench_typecheck_impl");
	});

	ankerl::nanobench::Bench().minEpochIterations(100).run("swi::TypeCheck", []{
		system("echo \"forall(typecheck_function(add,call), format('~q~n', [typecheck_function(add,call)])).\" | swipl " BENCHMARK_PATH "/type_check.pl");
	});

	ankerl::nanobench::Bench().minEpochIterations(1000).run("souffle::TypeCheck", []{
		system("souffle " BENCHMARK_PATH "/type_check.dl");
	});

	system("souffle " BENCHMARK_PATH "/type_check.dl -o type_check.dl.exe");

	ankerl::nanobench::Bench().minEpochIterations(100).run("souffle::compiled::TypeCheck", []{
		system("./type_check.dl.exe");
	});
}