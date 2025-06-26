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

void graph100() {
	ankerl::nanobench::Bench().minEpochIterations(100).run("doir::kanren::Graph100", []{
		system("./graph100.ecs");
	});

	ankerl::nanobench::Bench().minEpochIterations(100).run("swi::Graph100", []{
		system("echo \"forall(path(X,Y), format('~q~n', [path(X,Y)])).\" | swipl " BENCHMARK_PATH "/graph100.pl");
	});

	ankerl::nanobench::Bench().minEpochIterations(100).run("souffle::Graph100", []{
		system("souffle " BENCHMARK_PATH "/graph100.dl");
	});

	system("souffle " BENCHMARK_PATH "/graph100.dl -o graph100.dl.exe");

	ankerl::nanobench::Bench().minEpochIterations(100).run("souffle::compiled::Graph100", []{
		system("./graph100.dl.exe");
	});
}