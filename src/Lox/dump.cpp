#include <format>
#include "lox.hpp"

#include <fp/string.hpp>

namespace doir::Lox {
	fp_string dump_literal(TrivialModule& module, ecs::entity_t root) {
		assert(module.has_component<literal>(root));
		fp::builder::string res = nullptr;
		if(module.has_component<bool>(root))
			res << (module.get_component<bool>(root) ? "true" : "false");
		else if(module.has_component<string>(root)) {
			auto lexeme = module.get_component<doir::comp::lexeme>(root).view(module.buffer);
			res << lexeme;
		} else if(module.has_component<double>(root))
			res << module.get_component<double>(root);
		else res << "null";
		return res.release();
	}

	fp_string dump(TrivialModule& module, ecs::entity_t root /* = 1*/, size_t depth /* = 0 */) {
		fp::raii::string indent = fp::raii::string{"\t"}.replicate(depth);
		// std::string indent(depth, '\t');
		auto end = [&](fp::builder::string& s) {
			if(module.has_component<doir::comp::children>(root)) {
				auto& children = module.get_component<doir::comp::children>(root);
				s << " (" << root << " ↓" << children.total << ")";
			} else s << " (" << root << ")";

			if(module.has_component<addresses>(root)) {
				auto& addresses = module.get_component<struct addresses>(root);
				s << " [" << addresses.res << ", " << addresses.a << ", " << addresses.b << "]";
			}
			s << "\n";
		};
		fp::builder::string res = nullptr;
		if(module.has_component<literal>(root)) {
			auto lit = fp::raii::string{dump_literal(module, root)};
			end(res << indent << lit);
		} else if(module.has_component<variable>(root)) {
			auto& ref = module.get_component<entity_reference>(root);
			auto target = ref.looked_up() ? fp::builder::string{} << ref.entity : fp::builder::string{"???"};
			end(res << indent << "var:" << ref.lexeme.view(module.buffer) << " -> " << target);
		} else if(module.has_component<not_>(root)) {
			auto& op = module.get_component<operation>(root);
			end(res << indent << "! [not]");
			res << dump(module, op.a, depth + 1);
		} else if(module.has_component<negate>(root)) {
			auto& op = module.get_component<operation>(root);
			end(res << indent << "- [negate]");
			res << dump(module, op.a, depth + 1);
		} else if(module.has_component<add>(root)) {
			auto& op = module.get_component<operation>(root);
			end(res << indent << "+ [add]");
			res << dump(module, op.a, depth + 1);
			res << dump(module, op.b, depth + 1);
		} else if(module.has_component<subtract>(root)) {
			auto& op = module.get_component<operation>(root);
			end(res << indent << "- [subtract]");
			res << dump(module, op.a, depth + 1);
			res << dump(module, op.b, depth + 1);
		} else if(module.has_component<multiply>(root)) {
			auto& op = module.get_component<operation>(root);
			end(res << indent << "* [multiply]");
			res << dump(module, op.a, depth + 1);
			res << dump(module, op.b, depth + 1);
		} else if(module.has_component<divide>(root)) {
			auto& op = module.get_component<operation>(root);
			end(res << indent << "/ [divide]");
			res << dump(module, op.a, depth + 1);
			res << dump(module, op.b, depth + 1);
		} else if(module.has_component<or_>(root)) {
			auto& op = module.get_component<operation>(root);
			end(res << indent << "or");
			res << dump(module, op.a, depth + 1);
			res << dump(module, op.b, depth + 1);
		} else if(module.has_component<and_>(root)) {
			auto& op = module.get_component<operation>(root);
			end(res << indent << "and");
			res << dump(module, op.a, depth + 1);
			res << dump(module, op.b, depth + 1);
		} else if(module.has_component<equal_to>(root)) {
			auto& op = module.get_component<operation>(root);
			end(res << indent << "== [equal]");
			res << dump(module, op.a, depth + 1);
			res << dump(module, op.b, depth + 1);
		} else if(module.has_component<not_equal_to>(root)) {
			auto& op = module.get_component<operation>(root);
			end(res << indent << "!= [not equal]");
			res << dump(module, op.a, depth + 1);
			res << dump(module, op.b, depth + 1);
		} else if(module.has_component<greater_than>(root)) {
			auto& op = module.get_component<operation>(root);
			end(res << indent << "> [greater]");
			res << dump(module, op.a, depth + 1);
			res << dump(module, op.b, depth + 1);
		} else if(module.has_component<less_than>(root)) {
			auto& op = module.get_component<operation>(root);
			end(res << indent << "< [less]");
			res << dump(module, op.a, depth + 1);
			res << dump(module, op.b, depth + 1);
		} else if(module.has_component<greater_than_equal_to>(root)) {
			auto& op = module.get_component<operation>(root);
			end(res << indent << ">= [greater equal]");
			res << dump(module, op.a, depth + 1);
			res << dump(module, op.b, depth + 1);
		} else if(module.has_component<less_than_equal_to>(root)) {
			auto& op = module.get_component<operation>(root);
			end(res << indent << "<= [less equal]");
			res << dump(module, op.a, depth + 1);
			res << dump(module, op.b, depth + 1);
		} else if(module.has_component<print>(root)) {
			auto& op = module.get_component<operation>(root);
			end(res << indent << "print");
			res << dump(module, op.a, depth + 1);
		} else if(module.has_component<return_>(root)) {
			auto* op = module.has_component<operation>(root) ? &module.get_component<operation>(root) : nullptr;
			end(res << indent << "return");
			if(op) res << dump(module, op->a, depth + 1);
		} else if(module.has_component<while_>(root)) {
			auto& op = module.get_component<operation>(root);
			end(res << indent << "while:condition:");
			res << dump(module, op.a, depth + 1);
			res << indent << "while:then:" << "\n";
			res << dump(module, op.b, depth + 1);
		} else if(module.has_component<if_>(root)) {
			auto& op = module.get_component<operation>(root);
			end(res << indent << "if:condition:");
			res << dump(module, op.a, depth + 1);
			res << indent << "if:then:" << "\n";
			res << dump(module, op.b, depth + 1);
			if(op.c){
				res << indent << "if:else:" << "\n";
				res << dump(module, op.c, depth + 1);
			}
		} else if(module.has_component<Module::HashtableComponent<variable_declare>>(root)) {
			auto& var = get_key(module.get_component<Module::HashtableComponent<variable_declare>>(root));
			end(res << indent << "declare:var:" << var.name.view(module.buffer));
		} else if(module.has_component<Module::HashtableComponent<parameter_declare>>(root)) {
			auto& param = get_key(module.get_component<Module::HashtableComponent<parameter_declare>>(root));
			end(res << indent << "declare:param:" << param.name.view(module.buffer));
		} else if(module.has_component<Module::HashtableComponent<function_declare>>(root)) {
			auto& decl = get_key(module.get_component<Module::HashtableComponent<function_declare>>(root));
			auto* params = module.has_component<parameters>(root) ? &module.get_component<parameters>(root) : nullptr;
			auto& block = module.get_component<struct block>(root);
			end(res << indent << "declare:fun:" << decl.name.view(module.buffer));
			if(params) for(auto param: params->iterate(module))
				res << dump(module, param, depth + 1);
			res << indent << "{" << "\n";
			for(auto e: block.children.iterate(module))
				res << dump(module, e, depth + 1);
			res << indent << "}" << "\n";
		} else if(module.has_component<assign>(root)){
			auto& op = module.get_component<operation>(root);
			end(res << indent << "assign:");
			res << dump(module, op.a, depth + 1);
			res << indent << "=" << "\n";
			res << dump(module, op.b, depth + 1);
		} else if(module.has_component<call>(root)){
			auto& call = module.get_component<struct call>(root);
			end(res << indent << "call:");
			res << dump(module, call.parent, depth + 1);
			res << indent << "call:args:" << "\n";
			for(auto e: call.children.iterate(module))
				res << dump(module, e, depth + 1);
		} else if(module.has_component<block>(root)){
			auto& block = module.get_component<struct block>(root);
			end(res << indent << "{");
			for(auto e: block.children.iterate(module))
				res << dump(module, e, depth + 1);
			res << indent << "}" << "\n";
		} else if(module.has_component<body_marker>(root)) {
			auto& marker = module.get_component<body_marker>(root);
			end(res << indent << "skip while iterating -> " << marker.skipTo);
		} else
			end(res << "<Unknown Component>");
		return res.release();
	}
}