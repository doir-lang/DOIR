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

void graph15() {
	ankerl::nanobench::Bench().minEpochIterations(100).run("doir::kanren::Graph15", []{
		system("./graph15.ecs");
	});

	ankerl::nanobench::Bench().minEpochIterations(100).run("swi::Graph15", []{
		system("echo \"forall(path(X,Y), format('~q~n', [path(X,Y)])).\" | swipl " BENCHMARK_PATH "/graph15.pl");
	});

	ankerl::nanobench::Bench().minEpochIterations(100).run("souffle::Graph15", []{
		system("souffle " BENCHMARK_PATH "/graph15.dl");
	});

	system("souffle " BENCHMARK_PATH "/graph15.dl -o graph15.dl.exe");

	ankerl::nanobench::Bench().minEpochIterations(100).run("souffle::compiled::Graph15", []{
		system("./graph15.dl.exe");
	});
}