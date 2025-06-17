#pragma once

#include "../module.hpp"
#include "../components.hpp"

#include "fp/dynarray.hpp"
#include <array>

namespace doir::Lox {

	inline namespace components {
		namespace interpreter { struct skippable {}; }

		struct null {};
		struct variable {};
		struct string {};
		struct literal {};

		struct block_children_entry: public list_entry { auto iterate(ecs::TrivialModule& module) {
			return iterate_impl<ecs::entity_t, block_children_entry>{*this, module};
		}};
		struct block {
			ecs::Entity parent; block_children_entry children = {ecs::invalid_entity}; ecs::Entity children_end = ecs::invalid_entity;
			static void swap_entities(block& b, ecs::TrivialModule& module, ecs::entity_t eA, ecs::entity_t eB) {
				if(b.parent == eA) b.parent = eB;
				else if(b.parent == eB) b.parent = eA;

				if(b.children.next == eA) b.children.next = eB;
				else if(b.children.next == eB) b.children.next = eA;
				if(b.children_end == eA) b.children_end = eB;
				else if(b.children_end == eB) b.children_end = eA;
			}

			void push_back_child(TrivialModule& module, ecs::entity_t child) {
				if(children_end == ecs::invalid_entity)
					children.set_next<block_children_entry>(module, child, ecs::invalid_entity);
				else
					module.get_component<block_children_entry>(children_end).set_next<block_children_entry>(module, child, children_end);
				children_end = child;
			}

			void push_front_child(TrivialModule& module, ecs::entity_t child) {
				auto old = children.next;
				children.set_next<block_children_entry>(module, child, ecs::invalid_entity);
				module.get_component<block_children_entry>(child).set_next(module, old);
			}

			void pop_back_child(TrivialModule& module) {
				auto& back = module.get_component<block_children_entry>(children_end);
				if(back.previous == ecs::invalid_entity) {
					children = {ecs::invalid_entity}; 
					children_end = ecs::invalid_entity;
					return;
				}
				auto& second_back = module.get_component<block_children_entry>(back.previous);

				second_back.next = ecs::invalid_entity;
				children_end = back.previous;
			}

			size_t size(TrivialModule& module) {
				size_t count = 0;
				for(auto _: children.iterate(module))
					++count;
				return count;
			}

			ecs::Entity access(TrivialModule& module, size_t i) {
				size_t count = 0;
				for(auto e: children.iterate(module))
					if(count == i)
						return e;
					else ++count;
				return ecs::invalid_entity;
			}

			// void finalize_list(TrivialModule& module) {
			// 	module.get_or_add_component<block_children_entry>(children_end).set_next<block_children_entry>(module, 0, children_end);
			// }
		};
		struct call: public block {}; // parent -> object being called on, children -> arguments
		// struct trailing_call {};

		struct declare {
			doir::lexeme name;
			ecs::Entity parent; // Parent block
			bool operator==(const declare& o) const {
				return parent == o.parent && fp_string_view_equal(name.view(doir::TrivialModule::get_current_buffer()), o.name.view(doir::TrivialModule::get_current_buffer()));
			}
			static void swap_entities(declare& decl, ecs::TrivialModule& module, ecs::entity_t eA, ecs::entity_t eB) {
				if(decl.parent == eA) decl.parent = eB;
				else if(decl.parent == eB) decl.parent = eA;
			}
		};
		struct variable_declare : public declare {};
		struct function_declare : public declare { size_t recursion = 0; };
		struct parameter_declare : public declare {};
		struct parameters_entry: public list_entry { auto iterate(ecs::TrivialModule& module) {
			return iterate_impl<ecs::entity_t, parameters_entry>{*this, module};
		}};
		struct parameters : doir::list<parameters_entry> {
			static void swap_entities(struct parameters& params, ecs::TrivialModule& module, ecs::entity_t eA, ecs::entity_t eB) {
				if(params.children.next == eA) params.children.next = eB;
				else if(params.children.next == eB) params.children.next = eA;
				if(params.children_end == eA) params.children_end = eB;
				else if(params.children_end == eB) params.children_end = eA;
			}
		};
		struct body_marker {
			ecs::Entity skipTo;
			static void swap_entities(body_marker& mark, ecs::TrivialModule& module, ecs::entity_t eA, ecs::entity_t eB) {
				if(mark.skipTo == eA) mark.skipTo = eB;
				else if(mark.skipTo == eB) mark.skipTo = eA;
			}
		};

		struct operation { // Condition, Then, Else, Marker
			ecs::Entity a = 0, b = 0, c = 0, d = 0;
			std::pair<ecs::Entity&, ecs::Entity&> pair() { return {a, b}; }
			const std::array<ecs::Entity, 4> array() const { return std::array<ecs::Entity, 4>{a, b, c, d}; }
			static void swap_entities(operation& op, ecs::TrivialModule& module, ecs::entity_t eA, ecs::entity_t eB) {
				if(op.a == eA) op.a = eB;
				else if(op.a == eB) op.a = eA;
				if(op.b == eA) op.b = eB;
				else if(op.b == eB) op.b = eA;
				if(op.c == eA) op.c = eB;
				else if(op.c == eB) op.c = eA;
				if(op.d == eA) op.d = eB;
				else if(op.d == eB) op.d = eA;
			}
		};

		struct not_ {};
		struct negate {};
		struct divide {};
		struct multiply {};
		struct add {};
		struct subtract {};
		struct less_than {};
		struct greater_than {};
		struct less_than_equal_to {};
		struct greater_than_equal_to {};
		struct equal_to {};
		struct not_equal_to {};
		struct and_ {};
		struct or_ {};
		struct assign {};
		struct print {};
		struct return_ {};
		struct while_ {};
		struct if_ {};

		struct addresses { 
			ecs::Entity res, a, b; 
			static void swap_entities(addresses& tac, ecs::TrivialModule& module, ecs::entity_t eA, ecs::entity_t eB) {
				if(tac.res == eA) tac.res = eB;
				else if(tac.res == eB) tac.res = eA;
				if(tac.a == eA) tac.a = eB;
				else if(tac.a == eB) tac.a = eA;
				if(tac.b == eA) tac.b = eB;
				else if(tac.b == eB) tac.b = eA;
			}
		};
	}
	namespace comp = component;

	std::pair<TrivialModule, ecs::entity_t> parse_view(const fp_string_view view);
	std::pair<TrivialModule, ecs::entity_t> parse(const fp_string string);

	fp_string dump(TrivialModule& module, ecs::entity_t root = 1, size_t depth = 0);

	void sort_parse_into_reverse_post_order_traversal(TrivialModule& module, ecs::entity_t root);
	size_t calculate_child_count(TrivialModule& module, ecs::entity_t root = 1, bool annotate = false);

	void lookup_references(TrivialModule& module, bool clear_references = true);
	bool verify_references(TrivialModule& module);
	bool verify_redeclarations(TrivialModule& module);
	bool verify_call_arrities(TrivialModule& module);
	
	void build_3ac(TrivialModule& module);
	fp_string dump_3ac(TrivialModule& module);

	bool interpret(TrivialModule& module);

	fp_dynarray(std::byte) to_binary(TrivialModule& module, ecs::entity_t root);
	std::pair<TrivialModule, ecs::entity_t> from_binary(fp_dynarray(std::byte));
}



namespace fnv {
	template<>
	struct fnv1a_64<doir::Lox::declare>{
		size_t operator()(const doir::Lox::declare& d) const noexcept {
			size_t h1 = fnv1a_64<fp_string_view>{}(d.name.view(doir::TrivialModule::get_current_buffer()));
			size_t h2 = fnv1a_64<size_t>{}(d.parent);
			return h1 ^ (h2 << 1); // Default combine algorithm off the cpp documentation
		}
	};

	template<>
	struct fnv1a_64<doir::Lox::function_declare>{
		size_t operator()(const doir::Lox::function_declare& d) const noexcept {
			return fnv1a_64<doir::Lox::declare>{}(d);
		}
	};

	template<>
	struct fnv1a_64<doir::Lox::variable_declare>{
		size_t operator()(const doir::Lox::variable_declare& d) const noexcept {
			return fnv1a_64<doir::Lox::declare>{}(d);
		}
	};
}