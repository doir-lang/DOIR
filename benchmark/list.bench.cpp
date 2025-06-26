#define DOIR_NO_PROFILING
#define DOIR_IMPLEMENTATION
#define FP_IMPLEMENTATION
#include "../src/ECS/ecs.h"

#include "../src/ECS/relational.hpp"

#include <nowide/iostream.hpp>
#include <nanobench.h>

int main() {
	ankerl::nanobench::Bench().minEpochIterations(100000).run("doir::kanren::List", []{
		system("./bench_list_impl");
	});

	ankerl::nanobench::Bench().minEpochIterations(100).run("swi::List", []{
		system("echo \"append_lists([a, b], [c, d], X).\" | swipl " BENCHMARK_PATH "/list.pl");
	});

	ankerl::nanobench::Bench().minEpochIterations(1000).run("souffle::List", []{
		system("souffle " BENCHMARK_PATH "/list.dl");
	});

	system("souffle " BENCHMARK_PATH "/list.dl -o list.dl.exe");

	ankerl::nanobench::Bench().minEpochIterations(1000).run("souffle::compiled::List", []{
		system("./list.dl.exe");
	});
}