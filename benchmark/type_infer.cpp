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
	} else return out << "<var:" << std::get<kr::Variable>(t).id << ">";
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

int main() {
	doir::ecs::RelationalModule mod; doir::ecs::Entity::set_current_module(mod);
	doir::ecs::Entity i32 = mod.create_entity();
	i32.add_component<std::string>() = "i32";
	doir::ecs::Entity u1 = mod.create_entity();
	u1.add_component<std::string>() = "u1";
	doir::ecs::Entity pu8 = mod.create_entity();
	pu8.add_component<std::string>() = "pu8";

	struct function_types: public doir::ecs::Relation<std::dynamic_extent, true> {}; // First is return, rest are parameters
	struct arguments: public doir::ecs::Relation<> {};
	struct call : public doir::ecs::Relation<1> {};
	struct type_of: public doir::ecs::Relation<1, true> {};

	doir::ecs::Entity A = mod.create_entity();
	A.add_component<type_of>() = {{{i32}}};
	A.add_component<std::string>() = "A";
	doir::ecs::Entity B = mod.create_entity();
	B.add_component<type_of>() = {{{i32}}};
	B.add_component<std::string>() = "B";

	auto T = mod.next_logic_variable();
	doir::ecs::Entity add = mod.create_entity();
	add.add_component<function_types>() = {{{T}, {T}, {T}}};
	add.add_component<std::string>() = "add";

	doir::ecs::Entity call = mod.create_entity();
	call.add_component<struct call>() = {{add}};
	call.add_component<arguments>() = {{A, B}};

	constexpr auto typecheck_function = [](doir::ecs::Entity function, doir::ecs::Entity call) {
		return kr::next_variables([=](kr::Variable func_type, kr::Variable param_types, kr::Variable args, kr::Variable arg_types) {
			return kr::conjunction(
				doir::ecs::related_entities_list<function_types>({function}, {func_type}),
				kr::split_tail({func_type}, {param_types}), 
				doir::ecs::related_entities_list<arguments>({call}, {args}),
				kr::map({args}, {arg_types}, doir::ecs::related_entities<type_of>),
				kr::eq({param_types}, {arg_types})
			);
		});
	};
	auto g = typecheck_function(add, call);

	for (const auto& [v, val] : kr::all_substitutions(g, mod.logic_state)) 
		if (std::holds_alternative<kr::Variable>(v)) {
			auto id = std::get<kr::Variable>(v).id;
			nowide::cout << "Var " << id << " = " << val << "\n";
		}
}