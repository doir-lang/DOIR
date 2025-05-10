#include "kanren.hpp"
#include "entity.hpp"

namespace doir::ecs { inline namespace relational {

	struct RelationBase {}; // Used for constraints

	// Base
	template<size_t N = std::dynamic_extent>
	struct Relation : public RelationBase {
		std::array<Entity, N> related;

		Relation() {}
		Relation(std::array<Entity, N> a): related(a) {}
		Relation(std::initializer_list<Entity> e) : related(e) {}
		Relation(Relation&&) = default;
		Relation(const Relation&) = default;
		Relation& operator=(Relation&&) = default;
		Relation& operator=(const Relation&) = default;
	};
	template<>

	struct Relation<std::dynamic_extent> : public RelationBase {
		std::vector<Entity> related;

		Relation() {}
		Relation(std::vector<Entity> a): related(a) {}
		Relation(std::initializer_list<Entity> e) : related(e) {}
		Relation(Relation&&) = default;
		Relation(const Relation&) = default;
		Relation& operator=(Relation&&) = default;
		Relation& operator=(const Relation&) = default;
	};

	struct RelationalModule : public TrivialModule {
		std::unordered_map<component_t, entity_t> component_lookup;

		Entity get_component_entity(component_t componentID) {
			DOIR_ZONE_SCOPED_AGGRO;
			if(component_lookup.contains(componentID)) return component_lookup[componentID];

			return component_lookup[componentID] = create_entity();
		}
		template<typename T, size_t Unique = 0>
		inline Storage& get_component_entity() noexcept { DOIR_ZONE_SCOPED_AGGRO; return get_component_entity(get_global_component_id<T, Unique>()); }

		std::optional<component_t> get_global_component_id_from_component_entity(entity_t e) {
			for(auto [c, ent]: component_lookup)
				if(e == ent)
					return c;
			return {};
		}


		template<std::derived_from<RelationBase> R>
		std::span<const Entity> get_related_entities(entity_t e) {
			if(!has_component<R>()) return {};
			return get_component<R>().related;
		}
	};

	kanren::Goal has_component(const kanren::Term& var, doir::ecs::component_t componentID) {
		return [=](kanren::State state) -> std::generator<kanren::State> {
			auto [m, s, c] = state;
	
			if(auto var_ = kanren::walk(var, s); var_)
				if(std::holds_alternative<doir::ecs::Entity>(*var_)) {
					if(m->has_component(std::get<doir::ecs::Entity>(*var_), componentID))
						co_yield state;
	
				} else if(std::holds_alternative<kanren::Variable>(*var_))
					for(size_t e = 0, size = fp_size(m->entity_component_indices); e < size; ++e) {
						auto comps = m->entity_component_indices[e];
						if(fp_size(comps) > componentID && comps[componentID] != doir::ecs::Storage::invalid) {
							s.emplace_front(std::get<kanren::Variable>(*var_), e);
							co_yield {m, s, c};
							s.pop_front();
						}
					}
		};
	}
	template<typename T, size_t Unique = 0>
	inline kanren::Goal has_component(const kanren::Term& var) { return has_component(var, get_global_component_id<T, Unique>()); }
	
	template<typename T, size_t Unique = 0>
	kanren::Goal related_entities(const kanren::Term& base, const kanren::Term& relate) {
		const auto componentID = get_global_component_id<T, Unique>();
		return [=](kanren::State state) -> std::generator<kanren::State> {
			auto [m, s, c] = state;
			auto base_ = kanren::walk(base, s);
			auto relate_ = kanren::walk(relate, s);
	
			if(base_ && relate_) {
				// Two variables... generate a sequence of every possible relation
				if(std::holds_alternative<kanren::Variable>(*base_) && std::holds_alternative<kanren::Variable>(*relate_)) {
					for(size_t e = 0, size = fp_size(m->entity_component_indices); e < size; ++e) 
						if(m->has_component<T, Unique>(e)) {
							auto related = m->get_component<T, Unique>(e).related;
							if(related.size()) {
								s.emplace_front(std::get<kanren::Variable>(*base_), e);
								for(auto r: related) {
									s.emplace_front(std::get<kanren::Variable>(*relate_), r);
									co_yield {m, s, c};
									s.pop_front();
								}
								s.pop_front();
							}
						}
				
				// Base variable, Relation fixed... generate sequence of all entities who have related in their relation list
				} else if(std::holds_alternative<kanren::Variable>(*base_) && std::holds_alternative<doir::ecs::Entity>(*relate_)) {
					for(size_t e = 0, size = fp_size(m->entity_component_indices); e < size; ++e) 
						if(m->has_component<T, Unique>(e)) {
							for(auto r: m->get_component<T, Unique>(e).related)
								if(r == std::get<doir::ecs::Entity>(*relate_)) {
									s.emplace_front(std::get<kanren::Variable>(*base_), e);
									co_yield {m, s, c};
									s.pop_front();
								}
						}
				
				// Base fixed, Relation variable... generate sequence of all entities in the fixed entity's relation list
				} else if(std::holds_alternative<doir::ecs::Entity>(*base_) && std::holds_alternative<kanren::Variable>(*relate_)) {
					auto e = std::get<doir::ecs::Entity>(*base_);
					if(m->has_component<T, Unique>(e)) {
						for(auto r: m->get_component<T, Unique>(e).related) {
							s.emplace_front(std::get<kanren::Variable>(*relate_), r);
							co_yield {m, s, c};
							s.pop_front();
						}
					}
				
				// Both fixed... confirm relate is in base's related list
				} else if(std::holds_alternative<doir::ecs::Entity>(*base_) && std::holds_alternative<doir::ecs::Entity>(*relate_)) {
					auto eBase = std::get<doir::ecs::Entity>(*base_);
					auto eRelate = std::get<doir::ecs::Entity>(*relate_);
					if(m->has_component<T, Unique>(eBase)) {
						for(auto r: m->get_component<T, Unique>(eBase).related)
							if(r == eRelate) {
								co_yield state;
								break;
							}
					}
				}
			}
		};
	}
}}