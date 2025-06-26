#define DOIR_NO_PROFILING
#define DOIR_IMPLEMENTATION
#define FP_IMPLEMENTATION
#include "../src/ECS/ecs.h"

#include "../src/ECS/relational.hpp"

#include <nowide/iostream.hpp>
#include <nanobench.h>

namespace kr = doir::kanren;

int main() {
	doir::ecs::RelationalModule mod; doir::ecs::Entity::set_current_module(mod);
	doir::ecs::Entity bart = mod.create_entity();
	bart.add_component<std::string>() = "Bart";
	doir::ecs::Entity lisa = mod.create_entity();
	lisa.add_component<std::string>() = "Lisa";
	doir::ecs::Entity homer = mod.create_entity();
	homer.add_component<std::string>() = "Homer";
	doir::ecs::Entity marg = mod.create_entity();
	marg.add_component<std::string>() = "Marg";
	doir::ecs::Entity abraham = mod.create_entity();
	abraham.add_component<std::string>() = "Abraham";
	doir::ecs::Entity jackie = mod.create_entity();
	jackie.add_component<std::string>() = "Jackie";

	struct parent : public doir::ecs::Relation<> {};
	bart.add_component<parent>() = {{homer, marg}};
	lisa.add_component<parent>() = {{homer, marg}};
	homer.add_component<parent>() = {{abraham}};
	marg.add_component<parent>() = {{jackie}};

	struct male : public doir::ecs::Tag {};
	bart.add_component<male>();
	homer.add_component<male>();
	abraham.add_component<male>();

	struct female : public doir::ecs::Tag {};
	lisa.add_component<female>();
	marg.add_component<female>();
	jackie.add_component<female>();

	auto ancestor = [](const kr::Term& child, const kr::Term& ancestor) -> kr::Goal auto {
		auto impl = [](const kr::Term& child, const kr::Term& ancestor, auto impl) -> std::function<std::generator<kr::State>(kr::State)> {
			return kr::next_variables([=](kr::Variable tmp) -> kr::Goal auto {
				return kr::disjunction(
					doir::ecs::related_entities<parent>(child, ancestor), 
					kr::conjunction(doir::ecs::related_entities<parent>(child, {tmp}), impl({tmp}, ancestor, impl))
				);
			});
		};
		return impl(child, ancestor, impl);
	};

	kr::State state{&mod};
	auto x = state.next_variable();
	auto y = state.next_variable();
	auto g = ancestor({x}, {y});

	for (const auto& [v, val] : kr::all_substitutions(g, state))
		if (std::holds_alternative<kr::Variable>(v) && std::holds_alternative<doir::ecs::Entity>(val)) {
			auto e = std::get<doir::ecs::Entity>(val);
			auto id = std::get<kr::Variable>(v).id;
			nowide::cout << "Var " << id << " = " << e.get_component<std::string>() << "\n";
		}
}