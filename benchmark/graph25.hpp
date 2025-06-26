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

void graph25() {
	ankerl::nanobench::Bench().minEpochIterations(100).run("doir::kanren::Graph25", []{
		system("./graph25.ecs");
	});

	ankerl::nanobench::Bench().minEpochIterations(100).run("swi::Graph25", []{
		system("echo \"forall(path(X,Y), format('~q~n', [path(X,Y)])).\" | swipl " BENCHMARK_PATH "/graph25.pl");
	});

	ankerl::nanobench::Bench().minEpochIterations(100).run("souffle::Graph25", []{
		system("souffle " BENCHMARK_PATH "/graph25.dl");
	});

	system("souffle " BENCHMARK_PATH "/graph25.dl -o graph25.dl.exe");

	ankerl::nanobench::Bench().minEpochIterations(100).run("souffle::compiled::Graph25", []{
		system("./graph25.dl.exe");
	});
}