#include "fp/string.h"
#include "lox.hpp"
#include <unordered_map>

namespace doir::Lox {
	inline namespace components {
		struct assignment_counter { size_t count = 0; };
	}

	void annotate_assignment(TrivialModule& module, ecs::Entity e) {
		++e.get_or_add_component<assignment_counter>(module).count;
	}

	void build_3ac(TrivialModule& module) {
		// Build 3AC
		for(ecs::Entity e = module.get_component<doir::children>(1).reverse_iteration_start(1); e--; ) {
			if(e.has_component<not_>(module) || e.has_component<negate>(module) ||
				e.has_component<divide>(module) || e.has_component<multiply>(module) ||
				e.has_component<add>(module) || e.has_component<subtract>(module) ||
				e.has_component<less_than>(module) || e.has_component<greater_than>(module) ||
				e.has_component<less_than_equal_to>(module) || e.has_component<greater_than_equal_to>(module) ||
				e.has_component<equal_to>(module) || e.has_component<not_equal_to>(module) ||
				e.has_component<and_>(module) || e.has_component<or_>(module)
			){
				auto& op = e.get_component<operation>();
				e.add_component<addresses>() = {e, op.a, op.b};
				annotate_assignment(module, e);
			} else if(e.has_component<assign>(module)) {
				auto& op = e.get_component<operation>();
				auto ref = op.a.get_component<doir::entity_reference>().resolve(module);
				e.add_component<addresses>() = {ref, op.b, 0};
				annotate_assignment(module, ref);
			} else if(e.has_component<variable>(module)) {
				if(ecs::Entity{e - 1}.has_component<assign>())
					continue; // This variable represents the lookup for an assignment (the assign should have 3AC instead)
				auto ref = e.get_component<doir::entity_reference>().resolve(module);
				e.add_component<addresses>() = {e, ref, 0};
				annotate_assignment(module, e);
			} else if(e.has_component<literal>(module)) {
				e.add_component<addresses>() = {e, 0, 0};
				annotate_assignment(module, e);
			}
		}

		// The tree has many redundant assignments ex:
		// 18 ← 6 immediate
		// 19 ← 18
		// 9 ← 19	// 18 should be used instead of 9
		std::unordered_map<ecs::entity_t, ecs::entity_t> substitutions;
		for(ecs::Entity e = module.get_component<doir::children>(1).reverse_iteration_start(1); e--; ) {
			if(!e.has_component<addresses>(module)) continue;
			
			auto& addresses = e.get_component<struct addresses>(module);
			if(substitutions.contains(addresses.a)) addresses.a = substitutions[addresses.a];
			if(substitutions.contains(addresses.b)) addresses.b = substitutions[addresses.b];

			auto assignments = addresses.res.get_component<assignment_counter>().count;
			if(assignments == 1 && addresses.b == 0 && addresses.a != 0) {
				// addresses.b == 0 -> assign, variable, or literal
				// addresses.a != 0 -> not a literal
				// So we have a value copy that is only assigned to once... why not just use the name we are copying from?
				substitutions[addresses.res] = addresses.a;
				e.remove_component<struct addresses>(module);
			}
		}

		module.release_storage<assignment_counter>();
	}

	fp_string dump_literal(TrivialModule& module, ecs::entity_t root);
	fp_string dump_3ac(TrivialModule& module) {
		fp::builder::string out = nullptr;
		for(ecs::Entity e = module.get_component<doir::children>(1).reverse_iteration_start(1); e--; ) {
			if(!e.has_component<addresses>(module)) continue;
			if(e.has_component<literal>(module)) {
				auto lit = fp::raii::string{dump_literal(module, e)};
				out << e << " ← " << lit << " immediate\n";
				continue;
			}

			const char* op = nullptr;
			{
				if(e.has_component<not_>(module))
					op = "!";
				else if(e.has_component<negate>(module) )
					op = "-";
				else if(e.has_component<divide>(module))
					op = "/";
				else if(e.has_component<multiply>(module) )
					op = "*";
				else if(e.has_component<add>(module))
					op = "+";
				else if(e.has_component<subtract>(module) )
					op = "-";
				else if(e.has_component<less_than>(module))
					op = "<";
				else if(e.has_component<greater_than>(module) )
					op = ">";
				else if(e.has_component<less_than_equal_to>(module) )
					op = "<=";
				else if(e.has_component<greater_than_equal_to>(module) )
					op = ">=";
				else if(e.has_component<equal_to>(module))
					op = "==";
				else if(e.has_component<not_equal_to>(module) )
					op = "!=";
				else if(e.has_component<and_>(module))
					op = "&&";
				else if(e.has_component<or_>(module))
					op = "||";
			}

			auto& addresses = e.get_component<struct addresses>(module);
			out << addresses.res << " ← " << addresses.a;
			if(op) out << ' ' << op << ' ' << addresses.b;
			out << "\n";
		}
		return out.release();
	}
}