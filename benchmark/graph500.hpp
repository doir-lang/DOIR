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

void graph500() {
	ankerl::nanobench::Bench().minEpochIterations(100).run("doir::kanren::Graph500", []{
		system("./graph500.ecs");
	});

	ankerl::nanobench::Bench().minEpochIterations(100).run("swi::Graph500", []{
		system("echo \"forall(path(X,Y), format('~q~n', [path(X,Y)])).\" | swipl " BENCHMARK_PATH "/graph500.pl");
	});

	ankerl::nanobench::Bench().minEpochIterations(100).run("souffle::Graph500", []{
		system("souffle " BENCHMARK_PATH "/graph500.dl");
	});

	system("souffle " BENCHMARK_PATH "/graph500.dl -o graph500.dl.exe");

	ankerl::nanobench::Bench().minEpochIterations(100).run("souffle::compiled::Graph500", []{
		system("./graph500.dl.exe");
	});
}