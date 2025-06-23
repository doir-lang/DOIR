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

std::ostream& operator<<(std::ostream& out, const kr::Term& t) {
	if(std::holds_alternative<doir::ecs::Entity>(t))
		return out << std::get<doir::ecs::Entity>(t).get_component<std::string>();
	else if(std::holds_alternative<std::list<kr::Term>>(t)) {
		out << "[";
		for(auto& e: std::get<std::list<kr::Term>>(t))
			out << e << ",";
		return out << "]";
	} else return out << "<term>";
}

kr::Goal auto debug_var(kr::Goal auto goal, const kr::Term& to_print) {
	return [=](kr::State state) -> std::generator<kr::State> {
		for(auto s: goal(state)) {
			auto var = kr::find(to_print, s.sub);
			nowide::cout << var << std::endl;
			co_yield s;
		}
	};
}

void graph5() {
	ankerl::nanobench::Bench().minEpochIterations(100).run("doir::kanren::Graph5", []{
		std::vector<doir::ecs::Entity> nodes;
		doir::ecs::RelationalModule mod; doir::ecs::Entity::set_current_module(mod);

		for (int i = 0; i < 5; ++i) {
			doir::ecs::Entity node = mod.create_entity();

			// Assign name "Node_i"
			std::ostringstream name;
			name << "N" << i;
			node.add_component<std::string>() = name.str();

			nodes.push_back(node);
		}

		struct edge : public doir::ecs::Relation<1> {};

		// Connect each node to the next using the `edge` relation
		for (int i = 0; i < 4; ++i)
			nodes[i].add_component<edge>() = {{nodes[i + 1]}};

		auto path = [](const kr::Term& start, const kr::Term& end) -> kr::Goal auto {
			auto impl = [](const kr::Term& start, const kr::Term& end, auto impl) -> std::function<std::generator<kr::State>(kr::State)> {
				return kr::disjunction(
					doir::ecs::related_entities<edge>(start, end),
					kr::next_variables([=](kr::Variable tmp) {
						return kr::conjunction(
							doir::ecs::related_entities<edge>(start, {tmp}), 
							impl({tmp}, end, impl),
							kr::passthrough_if_not(kr::eq(start, end)) // start != end
						);
					})
				);
			};
			return impl(start, end, impl);
		};

		kr::State state{&mod};
		auto x = state.next_variable();
		auto y = state.next_variable();
		auto goal = kr::conjunction(
			doir::ecs::stream_of_all_entities(x),
			doir::ecs::stream_of_all_entities(y),
			path({x}, {y})
		);

		size_t count = 0;
		for (const auto& [v, val] : kr::all_substitutions(goal, state)) {
			++count;
			if (std::holds_alternative<kr::Variable>(v) && std::holds_alternative<doir::ecs::Entity>(val)) {
				auto id = std::get<kr::Variable>(v).id;
				auto e = std::get<doir::ecs::Entity>(val);
				nowide::cout << "Var " << id << " = " << e.get_component<std::string>() << "\n";
			}
		}
		if(count == 0) nowide::cout << "No Solutions!" << std::endl;
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