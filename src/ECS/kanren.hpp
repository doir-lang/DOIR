#include "ecs.hpp"
#include "entity.hpp"

#include <compare>
#include <list>
#include <optional>
#include <utility>
#include <functional>
#include <generator>
#include <unordered_set>

namespace doir::kanren {

	namespace detail {
		// Primary template
		template<typename T>
		struct function_traits;

		// Specialization for function pointer
		template<typename R, typename... Args>
		struct function_traits<R(*)(Args...)> {
			using result_type = R;
			using argument_types = std::tuple<Args...>;
			static constexpr std::size_t arity = sizeof...(Args);
		};

		// Specialization for std::function
		template<typename R, typename... Args>
		struct function_traits<std::function<R(Args...)>> {
			using result_type = R;
			using argument_types = std::tuple<Args...>;
			static constexpr std::size_t arity = sizeof...(Args);
		};

		// Specialization for member function pointers (const and non-const)
		template<typename C, typename R, typename... Args>
		struct function_traits<R(C::*)(Args...) const> {
			using result_type = R;
			using argument_types = std::tuple<Args...>;
			static constexpr std::size_t arity = sizeof...(Args);
		};

		template<typename C, typename R, typename... Args>
		struct function_traits<R(C::*)(Args...)> {
			using result_type = R;
			using argument_types = std::tuple<Args...>;
			static constexpr std::size_t arity = sizeof...(Args);
		};

		// Fallback: deduce from operator()
		template<typename F>
		struct function_traits : function_traits<decltype(&F::operator())> {};
	}
	
	struct Variable {
		size_t id;
		bool operator==(const Variable& other) const { return id == other.id; }
		std::strong_ordering operator<=>(const Variable& other) const { return id <=> other.id; }
		explicit operator size_t() { return id; }

		static Variable next(struct State&);
		void become_next_variable(struct State& s) { *this = next(s); }
	};

	struct Term: public std::variant<Variable, /* std::pair<Term*, Term*>, */ ecs::Entity> {};
	size_t term2size_t(const Term& term) {
		size_t out;
		std::visit([&out](auto a) {
			out = (size_t)a;
		}, term);
		return out;
	}

	using Substitution = std::list<std::pair<Variable, Term>>;
	struct State {
		ecs::TrivialModule* module;
		Substitution sub;
		size_t counter = 0;
		
		Variable next_variable() { return Variable::next(*this); }
	};
	using Goal = std::function<std::generator<State>(State)>;

	Variable Variable::next(State& state) {
		return {state.counter++};
	}

	inline namespace micro {
		std::optional<Term> walk(const Term& u, const Substitution& s) {
			if (std::holds_alternative<Variable>(u)) {
				const Variable& var = std::get<Variable>(u);
				for (const auto& [v, val] : s) 
					if (var == v) 
						return walk(val, s);
			}
			return u;
		}
		std::optional<Substitution> unify(const Term& u, const Term& v, Substitution s) {
			auto u_ = walk(u, s);
			auto v_ = walk(v, s);
			if (!u_ || !v_) return std::nullopt;

			if (std::holds_alternative<Variable>(*u_)) {
				if (std::holds_alternative<Variable>(*v_) && std::get<Variable>(*u_) == std::get<Variable>(*v_)) return s;
				s.emplace_front(std::get<Variable>(*u_), *v_);
				return s;
			}

			if (std::holds_alternative<Variable>(*v_)) {
				s.emplace_front(std::get<Variable>(*v_), *u_);
				return s;
			}

			// if (std::holds_alternative<std::pair<Term*, Term*>>(*u_) && std::holds_alternative<std::pair<Term*, Term*>>(*v_)) {
			// 	const auto& p1 = std::get<std::pair<Term*, Term*>>(*u_);
			// 	const auto& p2 = std::get<std::pair<Term*, Term*>>(*v_);
			// 	auto s1 = unify(*p1.first, *p2.first, s);
			// 	if (!s1) return std::nullopt;
			// 	return unify(*p1.second, *p2.second, *s1);
			// }

			if (std::get<ecs::Entity>(*u_) == std::get<ecs::Entity>(*v_)) return s;

			return std::nullopt;
		}

		std::generator<State> unit(State s) {
			co_yield s;
		}

		std::generator<State> null() {
			co_return;
		}

		Goal eq(const Term& u, const Term& v) {
			return [=](State sc) -> std::generator<State> {
				auto [m, s, c] = sc;
				if (auto s_ = unify(u, v, s); s_) 
					co_yield {m, *s_, c};
			};
		}
		inline Goal operator==(const Term& u, const Term& v) { return eq(u, v); }

		Goal next_variable(std::convertible_to<std::function<Goal(Variable)>> auto f) {
			return [f](State state) -> std::generator<State> {
				Variable next{state.counter++};
				co_yield std::ranges::elements_of(f(next)(state));
			};
		}
		inline Goal fresh(std::convertible_to<std::function<Goal(Variable)>> auto f) { return next_variable(f); }

		template<typename F, size_t arity = detail::function_traits<F>::arity>
		Goal next_variables(const F& f) {
			return [f](State state) mutable -> std::generator<State> {
				Variable next{state.counter++};
				if constexpr(arity > 1) {
					auto b = [f, next](auto... args){
						return f(next, args...);
					};
					co_yield std::ranges::elements_of(next_variables<decltype(b), arity - 1>(b)(state));
				} else co_yield std::ranges::elements_of(f(next)(state));
			};
		}

		std::generator<State> mplus(std::generator<State> g1, std::generator<State> g2) {
			// co_yield std::ranges::elements_of(g1);
			// co_yield std::ranges::elements_of(g2);
			auto it1 = g1.begin();
			auto it2 = g2.begin();

			while (it1 != g1.end() || it2 != g2.end()) {
				if (it1 != g1.end()) {
					co_yield *it1;
					++it1;
				}
				if (it2 != g2.end()) {
					co_yield *it2;
					++it2;
				}
			}
		}

		Goal disjunction(Goal g1, Goal g2) {
			return [=](State state) {
				return mplus(g1(state), g2(state));
			};
		}
		inline Goal operator|(Goal g1, Goal g2) { return disjunction(g1, g2); }

		std::generator<State> bind(std::generator<State> g, Goal f) {
			for (auto s : g) 
				co_yield std::ranges::elements_of(f(s));
		}

		Goal conjunction(Goal g1, Goal g2) {
			return [=](State state) {
				return bind(g1(state), g2);
			};
		}
		inline Goal operator&(Goal g1, Goal g2) { return conjunction(g1, g2); }

	} // kanren::micro

	inline namespace alpha {
		template<typename F>
		Goal exists(F&& f) { return next_variables<F, detail::function_traits<F>::arity>(f); }
	} // kanren::alpha

	Goal condition(bool condition) {
		return [=](State state) -> std::generator<State> {
			if(condition)
				co_yield state;
		};
	}
	
	Goal condition(const Goal& g, bool cond) {
		return g & condition(cond);
	}
}

namespace std {
	template<>
	struct hash<std::pair<doir::kanren::Variable, doir::kanren::Term>> {
		size_t operator()(const std::pair<doir::kanren::Variable, doir::kanren::Term>& pair) const {
			return pair.first.id ^ doir::kanren::term2size_t(pair.second);
		}
	};

	bool operator==(const std::pair<doir::kanren::Variable, doir::kanren::Term>& a, const std::pair<doir::kanren::Variable, doir::kanren::Term>& b) {
		return a.first == b.first && doir::kanren::term2size_t(a.second) == doir::kanren::term2size_t(b.second);
	}
}

namespace doir::kanren { inline namespace query {
	std::generator<std::pair<Variable, Term>> unique_substitutions(auto& substitutions, std::unordered_set<std::pair<Variable, Term>>& found)
		requires(std::convertible_to<decltype(*substitutions.begin()), std::pair<Variable, Term>>)
	{
		for(auto& sub: substitutions)
			if(!found.contains(sub)) {
				found.insert(sub);
				co_yield sub;
			}
	}

	std::generator<std::pair<Variable, Term>> unique_substitutions(auto& substitutions)
		requires(std::convertible_to<decltype(*substitutions.begin()), std::pair<Variable, Term>>)
	{
		std::unordered_set<std::pair<Variable, Term>> found;
		co_yield std::ranges::elements_of(unique_substitutions(substitutions, found));
	}

	std::generator<std::pair<Variable, Term>> unique_substitutions(std::convertible_to<std::generator<State>> auto states) {
		std::unordered_set<std::pair<Variable, Term>> found;
		for (const auto& [module, sub, counter] : states)
			co_yield std::ranges::elements_of(unique_substitutions(sub, found));
	}

	std::generator<std::pair<Variable, Term>> unique_substitutions(Goal& goal, State& state) {
		co_yield std::ranges::elements_of(unique_substitutions(goal(state)));
	}

	std::generator<std::pair<Variable, Term>> all_substitutions(std::convertible_to<std::generator<State>> auto states) {
		for (const auto& [module, subs, counter] : states)
			for(const auto& sub: subs)
				co_yield sub;
	}

	std::generator<std::pair<Variable, Term>> all_substitutions(Goal auto& goal, State& state) {
		co_yield std::ranges::elements_of(all_substitutions(goal(state)));
	}
}}
