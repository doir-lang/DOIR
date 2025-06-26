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

void graph50() {
	ankerl::nanobench::Bench().minEpochIterations(100).run("doir::kanren::Graph50", []{
		system("./graph50.ecs");
	});

	ankerl::nanobench::Bench().minEpochIterations(100).run("swi::Graph50", []{
		system("echo \"forall(path(X,Y), format('~q~n', [path(X,Y)])).\" | swipl " BENCHMARK_PATH "/graph50.pl");
	});

	ankerl::nanobench::Bench().minEpochIterations(100).run("souffle::Graph50", []{
		system("souffle " BENCHMARK_PATH "/graph50.dl");
	});

	system("souffle " BENCHMARK_PATH "/graph50.dl -o graph50.dl.exe");

	ankerl::nanobench::Bench().minEpochIterations(100).run("souffle::compiled::Graph50", []{
		system("./graph50.dl.exe");
	});
}