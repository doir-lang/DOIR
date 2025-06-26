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

void graph5() {
	ankerl::nanobench::Bench().minEpochIterations(100).run("doir::kanren::Graph5", []{
		system("./graph5.ecs");
	});

	ankerl::nanobench::Bench().minEpochIterations(100).run("swi::Graph5", []{
		system("echo \"forall(path(X,Y), format('~q~n', [path(X,Y)])).\" | swipl " BENCHMARK_PATH "/graph5.pl");
	});

	ankerl::nanobench::Bench().minEpochIterations(100).run("souffle::Graph5", []{
		system("souffle " BENCHMARK_PATH "/graph5.dl");
	});

	system("souffle " BENCHMARK_PATH "/graph5.dl -o graph5.dl.exe");

	ankerl::nanobench::Bench().minEpochIterations(100).run("souffle::compiled::Graph5", []{
		system("./graph5.dl.exe");
	});
}