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

int main() {
	doir::ecs::RelationalModule mod; doir::ecs::Entity::set_current_module(mod);
	doir::ecs::Entity a = mod.create_entity();
	a.add_component<std::string>() = "A";
	doir::ecs::Entity b = mod.create_entity();
	b.add_component<std::string>() = "B";
	doir::ecs::Entity c = mod.create_entity();
	c.add_component<std::string>() = "C";
	doir::ecs::Entity d = mod.create_entity();
	d.add_component<std::string>() = "D";
	doir::ecs::Entity e = mod.create_entity();
	e.add_component<std::string>() = "E";

	kr::State state{&mod};
	auto x = state.next_variable();
	auto y = state.next_variable();
	// auto g = kr::eq({x}, {std::list<kr::Term>{{b}, {c}}}) & split_head_and_tail({a}, {x}, {y});
	// auto g = append({std::list<kr::Term>{}}, {std::list<kr::Term>{{c}, {d}}}, {x});
	// auto g = append({std::list<kr::Term>{{a}, {b}}}, {std::list<kr::Term>{{c}, {d}}}, {x});
	// auto g = append({a}, {b}, {x});
	// auto g = kr::conjunction(kr::append({std::list<kr::Term>{{a}, {b}}}, {std::list<kr::Term>{{c}, {d}}}, {y}), kr::passthrough_if_not(kr::element_of({y}, {e})));
	auto g = kr::append({std::list<kr::Term>{{a}, {b}}}, {std::list<kr::Term>{{c}, {d}}}, {x});

	for (const auto& [v, val] : kr::all_substitutions(g, state))
		if (std::holds_alternative<kr::Variable>(v)) {
			auto id = std::get<kr::Variable>(v).id;
			nowide::cout << "Var " << id << " = " << val << "\n";
		}
}