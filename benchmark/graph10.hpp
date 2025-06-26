#pragma once
#include <memory>
#define DOIR_NO_PROFILING
#define DOIR_IMPLEMENTATION
#define FP_IMPLEMENTATION
#include "../src/ECS/ecs.h"

#include "../src/ECS/relational.hpp"

#include <nowide/iostream.hpp>
#include <nanobench.h>

namespace kr = doir::kanren;

void graph10() {
	ankerl::nanobench::Bench().minEpochIterations(100).run("doir::kanren::Graph10", []{
		system("./graph10.ecs");
	});

	ankerl::nanobench::Bench().minEpochIterations(100).run("swi::Graph10", []{
		system("echo \"forall(path(X,Y), format('~q~n', [path(X,Y)])).\" | swipl " BENCHMARK_PATH "/graph10.pl");
	});

	ankerl::nanobench::Bench().minEpochIterations(100).run("souffle::Graph10", []{
		system("souffle " BENCHMARK_PATH "/graph10.dl");
	});

	system("souffle " BENCHMARK_PATH "/graph10.dl -o graph10.dl.exe");

	ankerl::nanobench::Bench().minEpochIterations(100).run("souffle::compiled::Graph10", []{
		system("./graph10.dl.exe");
	});
}