#define DOIR_NO_PROFILING
#define DOIR_IMPLEMENTATION
#define FP_IMPLEMENTATION
#include "../src/ECS/ecs.h"

#include "../src/ECS/relational.hpp"

#include <nowide/iostream.hpp>
#include <nanobench.h>

namespace kr = doir::kanren;

int main() {
	ankerl::nanobench::Bench().minEpochIterations(50000).run("doir::kanren::Simpsons", []{
		system("./bench_simpsons_impl");
	});

	ankerl::nanobench::Bench().minEpochIterations(100).run("swi::Simpsons", []{
		system("echo \"forall(ancestor(X,Y), format('~q~n', [ancestor(X,Y)])).\" | swipl " BENCHMARK_PATH "/simpsons.pl");
	});

	ankerl::nanobench::Bench().minEpochIterations(1000).run("souffle::Simpsons", []{
		system("souffle " BENCHMARK_PATH "/simpsons.dl");
	});

	system("souffle " BENCHMARK_PATH "/simpsons.dl -o simpsons.dl.exe");

	ankerl::nanobench::Bench().minEpochIterations(100).run("souffle::compiled::Simpsons", []{
		system("./simpsons.dl.exe");
	});
}