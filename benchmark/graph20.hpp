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

void graph20() {
	ankerl::nanobench::Bench().minEpochIterations(100).run("doir::kanren::Graph20", []{
		system("./graph20.ecs");
	});

	ankerl::nanobench::Bench().minEpochIterations(100).run("swi::Graph20", []{
		system("echo \"forall(path(X,Y), format('~q~n', [path(X,Y)])).\" | swipl " BENCHMARK_PATH "/graph20.pl");
	});

	ankerl::nanobench::Bench().minEpochIterations(100).run("souffle::Graph20", []{
		system("souffle " BENCHMARK_PATH "/graph20.dl");
	});

	system("souffle " BENCHMARK_PATH "/graph20.dl -o graph20.dl.exe");

	ankerl::nanobench::Bench().minEpochIterations(100).run("souffle::compiled::Graph20", []{
		system("./graph20.dl.exe");
	});
}