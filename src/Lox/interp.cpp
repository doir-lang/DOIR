#include "lox.hpp"
#include "nowide/iostream.hpp"
#include <cmath>
#include <limits>
#include <chrono>

namespace doir::Lox {
	enum class runtime_type {
		Invalid,
		Null,
		Number,
		Boolean,
		String,
	};

	runtime_type determine_runtime_type(TrivialModule& module, ecs::Entity e) {
		DOIR_ZONE_SCOPED_AGGRO;
		if(e.has_component<runtime_type>(module))
			return e.get_component<runtime_type>(module);
		else if(e.has_component<Lox::null>(module))
			return runtime_type::Null;
		else if(e.has_component<double>(module))
			return runtime_type::Number;
		else if(e.has_component<bool>(module))
			return runtime_type::Boolean;
		else if(e.has_component<Lox::string>(module))
			return runtime_type::String;
		else return runtime_type::Invalid;
	}

	fp::string get_token_string(TrivialModule& module, ecs::Entity e) {
		if(e.has_component<fp::string>(module))
			return e.get_component<fp::string>(module);
		auto lexeme = e.get_component<doir::lexeme>(module);
		lexeme.start += 1; lexeme.length -= 2; // Trim quotes
		return e.add_component<fp::string>() = fp::string_view{lexeme.view(module.buffer)}.make_dynamic();
	}

	void copy_runtime_value(TrivialModule& module, ecs::Entity dest, ecs::Entity source) {
		DOIR_ZONE_SCOPED_AGGRO;
		switch (determine_runtime_type(module, source)) {
		break; case runtime_type::Number: {
			auto dbg = dest.get_or_add_component<double>(module) = source.get_component<double>(module);
			dest.get_or_add_component<runtime_type>(module) = runtime_type::Number;
		} break; case runtime_type::Boolean: {
			auto dbg = dest.get_or_add_component<bool>(module) = source.get_component<bool>();
			dest.get_or_add_component<runtime_type>(module) = runtime_type::Boolean;
		} break; case runtime_type::String: {
			auto dbg = dest.get_or_add_component<fp::string>(module) = get_token_string(module, source);
			dest.get_or_add_component<runtime_type>(module) = runtime_type::String;
		} break; default:
			dest.get_or_add_component<runtime_type>(module) = runtime_type::Null;
		}
	}
	
	bool is_truthy(TrivialModule& module, ecs::Entity e) {
		DOIR_ZONE_SCOPED_AGGRO;
		switch (determine_runtime_type(module, e)) {
		break; case runtime_type::Null: return false;
		break; case runtime_type::Boolean: return e.get_component<bool>();
		break; default: return true;
		}
		return false; // TODO: Why is this necessary?
	}
	
	bool is_equal(TrivialModule& module, ecs::Entity a, ecs::Entity b) {
		DOIR_ZONE_SCOPED_AGGRO;
		auto aType = determine_runtime_type(module, a);
		auto bType = determine_runtime_type(module, b);
		if(aType == runtime_type::Null && bType == runtime_type::Null) return true;
		if(aType != bType) return false;

		switch (aType) {
			case runtime_type::Boolean: return a.get_component<bool>() == b.get_component<bool>();
			case runtime_type::Number: return a.get_component<double>() == b.get_component<double>();
			case runtime_type::String: return get_token_string(module, a) == get_token_string(module, b);
			default: return false;
		}
	}
	
	
	
	bool interpret_add(TrivialModule& module, ecs::Entity target) {
		DOIR_ZONE_SCOPED_AGGRO;
		auto& op = target.get_component<operation>();
		if(determine_runtime_type(module, op.a) == runtime_type::Number && determine_runtime_type(module, op.b) == runtime_type::Number) {
			target.get_or_add_component<runtime_type>() = runtime_type::Number;
			auto dbg = target.get_or_add_component<double>() = op.a.get_component<double>() + op.b.get_component<double>();
			return true;
		} else if(determine_runtime_type(module, op.a) == runtime_type::String && determine_runtime_type(module, op.b) == runtime_type::String) {
			target.get_or_add_component<runtime_type>() = runtime_type::String;
			auto dbg = target.get_or_add_component<fp::string>() = get_token_string(module, op.a) + get_token_string(module, op.b);
			return true;
		}
		if(determine_runtime_type(module, op.a) != determine_runtime_type(module, op.b))
			nowide::cerr << target.entity << ": Operands have different types: " << (int)determine_runtime_type(module, op.a) << " and " << (int)determine_runtime_type(module, op.b) << std::endl;
		else nowide::cerr << target.entity << ": Only strings and numbers can be added!" << std::endl;
		return false;
	}
	
	bool interpret_subtract(TrivialModule& module, ecs::Entity target) {
		DOIR_ZONE_SCOPED_AGGRO;
		auto& op = target.get_component<operation>();
		if(determine_runtime_type(module, op.a) == runtime_type::Number && determine_runtime_type(module, op.b) == runtime_type::Number) {
			target.get_or_add_component<runtime_type>() = runtime_type::Number;
			auto dbg = target.get_or_add_component<double>() = op.a.get_component<double>() - op.b.get_component<double>();
			return true;
		}
		if(determine_runtime_type(module, op.a) != determine_runtime_type(module, op.b))
			nowide::cerr << target.entity << ": Operands have different types: " << (int)determine_runtime_type(module, op.a) << " and " << (int)determine_runtime_type(module, op.b) << std::endl;
		else nowide::cerr << target.entity << ": Only numbers can be subtracted!" << std::endl;
		return false;
	}
	
	bool interpret_multiply(TrivialModule& module, ecs::Entity target) {
		DOIR_ZONE_SCOPED_AGGRO;
		auto& op = target.get_component<operation>();
		if(determine_runtime_type(module, op.a) == runtime_type::Number && determine_runtime_type(module, op.b) == runtime_type::Number) {
			target.get_or_add_component<runtime_type>() = runtime_type::Number;
			auto dbg = target.get_or_add_component<double>() = op.a.get_component<double>() * op.b.get_component<double>();
			return true;
		}
		if(determine_runtime_type(module, op.a) != determine_runtime_type(module, op.b))
			nowide::cerr << target.entity << ": Operands have different types: " << (int)determine_runtime_type(module, op.a) << " and " << (int)determine_runtime_type(module, op.b) << std::endl;
		else nowide::cerr << target.entity << ": Only numbers can be multiplied!" << std::endl;
		return false;
	}
	
	bool interpret_divide(TrivialModule& module, ecs::Entity target) {
		DOIR_ZONE_SCOPED_AGGRO;
		auto& op = target.get_component<operation>();
		if(determine_runtime_type(module, op.a) == runtime_type::Number && determine_runtime_type(module, op.b) == runtime_type::Number) {
			target.get_or_add_component<runtime_type>() = runtime_type::Number;
			auto denom = op.b.get_component<double>();
			if(std::abs(denom) < std::numeric_limits<double>::epsilon())
				auto dbg = target.get_or_add_component<double>() = std::nan(":)");
			else auto dbg = target.get_or_add_component<double>() = op.a.get_component<double>() / denom;
			return true;
		}
		if(determine_runtime_type(module, op.a) != determine_runtime_type(module, op.b))
			nowide::cerr << target.entity << ": Operands have different types: " << (int)determine_runtime_type(module, op.a) << " and " << (int)determine_runtime_type(module, op.b) << std::endl;
		else nowide::cerr << target.entity << ": Only numbers can be divided!" << std::endl;
		return false;
	}
	
	bool interpret_less(TrivialModule& module, ecs::Entity target) {
		DOIR_ZONE_SCOPED_AGGRO;
		auto& op = target.get_component<operation>();
		if(determine_runtime_type(module, op.a) == runtime_type::Number && determine_runtime_type(module, op.b) == runtime_type::Number) {
			target.get_or_add_component<runtime_type>() = runtime_type::Boolean;
			auto dbg = target.get_or_add_component<bool>() = op.a.get_component<double>() < op.b.get_component<double>();
			return true;
		}
		if(determine_runtime_type(module, op.a) != determine_runtime_type(module, op.b))
			nowide::cerr << target.entity << ": Operands have different types: " << (int)determine_runtime_type(module, op.a) << " and " << (int)determine_runtime_type(module, op.b) << std::endl;
		else nowide::cerr << target.entity << ": Only numbers can be ordinally compared!" << std::endl;
		return false;
	}
	
	bool interpret_less_equal(TrivialModule& module, ecs::Entity target) {
		DOIR_ZONE_SCOPED_AGGRO;
		auto& op = target.get_component<operation>();
		if(determine_runtime_type(module, op.a) == runtime_type::Number && determine_runtime_type(module, op.b) == runtime_type::Number) {
			target.get_or_add_component<runtime_type>() = runtime_type::Boolean;
			auto dbg = target.get_or_add_component<bool>() = op.a.get_component<double>() <= op.b.get_component<double>();
			return true;
		}
		if(determine_runtime_type(module, op.a) != determine_runtime_type(module, op.b))
			nowide::cerr << target.entity << ": Operands have different types: " << (int)determine_runtime_type(module, op.a) << " and " << (int)determine_runtime_type(module, op.b) << std::endl;
		else nowide::cerr << target.entity << ": Only numbers can be ordinally compared!" << std::endl;
		return false;
	}
	
	bool interpret_greater(TrivialModule& module, ecs::Entity target) {
		DOIR_ZONE_SCOPED_AGGRO;
		auto& op = target.get_component<operation>();
		if(determine_runtime_type(module, op.a) == runtime_type::Number && determine_runtime_type(module, op.b) == runtime_type::Number) {
			target.get_or_add_component<runtime_type>() = runtime_type::Boolean;
			auto dbg = target.get_or_add_component<bool>() = op.a.get_component<double>() > op.b.get_component<double>();
			return true;
		}
		if(determine_runtime_type(module, op.a) != determine_runtime_type(module, op.b))
			nowide::cerr << target.entity << ": Operands have different types: " << (int)determine_runtime_type(module, op.a) << " and " << (int)determine_runtime_type(module, op.b) << std::endl;
		else nowide::cerr << target.entity << ": Only numbers can be ordinally compared!" << std::endl;
		return false;
	}
	
	bool interpret_greater_equal(TrivialModule& module, ecs::Entity target) {
		DOIR_ZONE_SCOPED_AGGRO;
		auto& op = target.get_component<operation>();
		if(determine_runtime_type(module, op.a) == runtime_type::Number && determine_runtime_type(module, op.b) == runtime_type::Number) {
			target.get_or_add_component<runtime_type>() = runtime_type::Boolean;
			auto dbg = target.get_or_add_component<bool>() = op.a.get_component<double>() >= op.b.get_component<double>();
			return true;
		}
		if(determine_runtime_type(module, op.a) != determine_runtime_type(module, op.b))
			nowide::cerr << target.entity << ": Operands have different types: " << (int)determine_runtime_type(module, op.a) << " and " << (int)determine_runtime_type(module, op.b) << std::endl;
		else nowide::cerr << target.entity << ": Only numbers can be ordinally compared!" << std::endl;
		return false;
	}
	
	bool interpret_negate(TrivialModule& module, ecs::Entity target) {
		DOIR_ZONE_SCOPED_AGGRO;
		auto& op = target.get_component<operation>();
		if(determine_runtime_type(module, op.a) == runtime_type::Number) {
			target.get_or_add_component<runtime_type>() = runtime_type::Number;
			auto dbg = target.get_or_add_component<double>() = -op.a.get_component<double>();
			return true;
		}
		nowide::cerr << target.entity << ": Only numbers can be negated!" << std::endl;
		return false;
	}
	
	bool interpret_not(TrivialModule& module, ecs::Entity target) {
		DOIR_ZONE_SCOPED_AGGRO;
		auto& op = target.get_component<operation>();
		target.get_or_add_component<runtime_type>() = runtime_type::Boolean;
		auto dbg = target.get_or_add_component<bool>() = !is_truthy(module, op.a);
		return true;
	}
	
	bool interpret_equal(TrivialModule& module, ecs::Entity target) {
		DOIR_ZONE_SCOPED_AGGRO;
		auto& op = target.get_component<operation>();
		target.get_or_add_component<runtime_type>() = runtime_type::Boolean;
		auto dbg = target.get_or_add_component<bool>() = is_equal(module, op.a, op.b);
		return true;
	}
	
	bool interpret_not_equal(TrivialModule& module, ecs::Entity target) {
		DOIR_ZONE_SCOPED_AGGRO;
		auto& op = target.get_component<operation>();
		target.get_or_add_component<runtime_type>() = runtime_type::Boolean;
		auto dbg = target.get_or_add_component<bool>() = !is_equal(module, op.a, op.b);
		return true;
	}
	
	bool interpret_print(TrivialModule& module, ecs::Entity target) {
		DOIR_ZONE_SCOPED_AGGRO;
		auto& op = target.get_component<operation>();
		switch (determine_runtime_type(module, op.a)) {
		break; case runtime_type::Null:
			nowide::cout << "nil" << std::endl;
			return true;
		break; case runtime_type::Number:
			nowide::cout << op.a.get_component<double>() << std::endl;
			return true;
		break; case runtime_type::Boolean:
			nowide::cout << (op.a.get_component<bool>() ? "true" : "false") << std::endl;
			return true;
		break; case runtime_type::String:
			nowide::cout << get_token_string(module, op.a) << std::endl;
			return true;
		break; default:
			nowide::cerr << target.entity << ": Attempted to print something with no value!" << std::endl;
			return false;
		}
		return false; // Necessary?
	}
	
	bool interpret_builtin_clock(TrivialModule& module, ecs::Entity target) {
		DOIR_ZONE_SCOPED_AGGRO;
		static auto first_called = std::chrono::steady_clock::now();
		std::chrono::duration<double> elapsed_seconds = std::chrono::steady_clock::now() - first_called;
		target.get_or_add_component<runtime_type>() = runtime_type::Number;
		auto dbg = target.get_or_add_component<double>() = elapsed_seconds.count();
		return true;
	}
	
	// Inserts the result of a call to interpret with the current state (&= valid, |= should_return) 
	std::pair<bool, bool> operator<<(std::pair<bool&, bool&> ref, std::pair<bool, bool> val) {
		ref.first &= val.first;
		ref.second |= val.second;
		return val;
	}
	std::pair<bool, bool> operator<<(std::tuple<bool&, bool&> ref, std::pair<bool, bool> val) {
		std::get<0>(ref) &= val.first;
		std::get<1>(ref) |= val.second;
		return val;
	}
	
	std::pair<bool, bool> interpret(TrivialModule& module, ecs::entity_t root, ecs::Entity returnTo = 0, std::optional<ecs::entity_t> _skipCheck = {}) {
		DOIR_ZONE_SCOPED_AGGRO;
		ecs::entity_t skipCheck = _skipCheck.value_or(root); // Token we should check any blocks against to determine weather or not to skip them
		bool valid = true;
		bool should_return = false;
	
		for(ecs::Entity e = module.get_component<doir::children>(root).reverse_iteration_start(root); (e--).entity > root && valid && !should_return; )
			if(e.has_component<interpreter::skippable>())	
				continue;

			else if(e.has_component<variable>()) {
				auto& ref = e.get_component<doir::entity_reference>();
				copy_runtime_value(module, e, ref.resolve(module));
			} else if(e.has_component<assign>()) {
				auto& op = e.get_component<operation>();
				auto& ref = op.a.get_component<doir::entity_reference>();
				copy_runtime_value(module, e, op.b);
				copy_runtime_value(module, ref.resolve(module), e);
			} else if(e.has_component<body_marker>()) {
				// Skip over any functions we aren't in!
				auto& marker = e.get_component<body_marker>();
				if(marker.skipTo != skipCheck)
					e = marker.skipTo + 1; // +1 so that when decrement during the next loop iteration we process the skipTo node
			} else if(e.has_component<return_>()) {
				if(returnTo == 0) {
					std::cerr << "Can't return from outside a function!" << std::endl;
					valid = false;
					continue;
				}
	
				if(e.has_component<operation>())
					copy_runtime_value(module, returnTo, e.get_component<operation>().a);
				// else module.has_attribute<lox::comp::Null>(returnTo);
				return {valid, true};
			} else if(e.has_component<call>()) {
				auto& call = e.get_component<struct call>();
				auto ref = call.parent.get_component<entity_reference>().resolve(module);
				if(ref == 2) { // The builtin function is processed specially
					valid &= interpret_builtin_clock(module, e);
					continue;
				}
				auto& params = ref.get_component<parameters>();
				auto& decl = get_key(ref.get_component<Module::HashtableComponent<function_declare>>());
	
				// Check for recursion
				if(decl.recursion) {
					// if(module.has_attribute<lox::comp::TrailingCall>(t))
					// 	doir::print_diagnostic(module, t, "Tail recursion detected.", doir::diagnostic_type::Warning) << std::endl;
					// else {
						std::cerr << "Recursion is not supported." << (ref != root ? " This indirectly recursive call is invalid." : "") << std::endl;
						return {false, false};
					// }
				}
	
				// Mark the call as started
				++decl.recursion;
	
				// Copy the argument values to the parameters
				for(size_t i = 0, size = params.size(module); i < size; ++i)
					copy_runtime_value(module, params.access(module, i), call.access(module, i));
				valid &= interpret(module, ref, e).first; // NOTE: Doesn't touch should_return!
	
				// Mark the call as finished
				--decl.recursion;
			} else if(e.has_component<if_>()) {
				auto& op = e.get_component<operation>();
				auto& [condition, then, else_, marker] = op.array();
	
				std::tie(valid, should_return) << interpret(module, condition, returnTo);
				if(is_truthy(module, condition))
					std::tie(valid, should_return) << interpret(module, then, returnTo, e);
				else if(else_ != 0)
					std::tie(valid, should_return) << interpret(module, else_, returnTo, e);
			} else if(e.has_component<while_>()) {
				auto& op = e.get_component<operation>();
	
				std::tie(valid, should_return) << interpret(module, op.a, returnTo);
				while(is_truthy(module, op.a) && !should_return) {
					// Evaluate the body of the loop
					std::tie(valid, should_return) << interpret(module, op.b, returnTo, op.b);
					// Evaluate the condition for the next truthyness check
					std::tie(valid, should_return) << interpret(module, op.a, returnTo);
				}
			} else if(e.has_component<and_>()) {
				auto& op = e.get_component<operation>();
				auto& [left, right, marker, _] = op.array();
	
				std::tie(valid, should_return) << interpret(module, left, returnTo);
				if(is_truthy(module, left)) {
					std::tie(valid, should_return) << interpret(module, right, returnTo);
					copy_runtime_value(module, e, right);
				} else copy_runtime_value(module, e, left);
			} else if(e.has_component<or_>()) {
				auto& op = e.get_component<operation>();
				auto& [left, right, marker, _] = op.array();
	
				std::tie(valid, should_return) << interpret(module, left, returnTo);
				if(!is_truthy(module, left)) {
					std::tie(valid, should_return) << interpret(module, right, returnTo);
					copy_runtime_value(module, e, right);
				} else copy_runtime_value(module, e, left);
			} else if(e.has_component<add>())
				valid &= interpret_add(module, e);
			else if(e.has_component<subtract>())
				valid &= interpret_subtract(module, e);
			else if(e.has_component<multiply>())
				valid &= interpret_multiply(module, e);
			else if(e.has_component<divide>())
				valid &= interpret_divide(module, e);
			else if(e.has_component<less_than>())
				valid &= interpret_less(module, e);
			else if(e.has_component<less_than_equal_to>())
				valid &= interpret_less_equal(module, e);
			else if(e.has_component<greater_than>())
				valid &= interpret_greater(module, e);
			else if(e.has_component<greater_than_equal_to>())
				valid &= interpret_greater_equal(module, e);
			else if(e.has_component<negate>())
				valid &= interpret_negate(module, e);
			else if(e.has_component<not_>())
				valid &= interpret_not(module, e);
			else if(e.has_component<equal_to>())
				valid &= interpret_equal(module, e);
			else if(e.has_component<not_equal_to>())
				valid &= interpret_not_equal(module, e);
			else if(e.has_component<print>())
				valid &= interpret_print(module, e);
			else {
				//throw std::runtime_error((std::stringstream{} << "Operation " << lox::to_string(type) << " not supported yet!").str().c_str());
			}
	
		// If this is a function call... mark that we returned null
		if(returnTo.entity > 0) returnTo.get_or_add_component<runtime_type>() = runtime_type::Null;
		return {valid, should_return};
	}
	bool interpret(TrivialModule& module) {
		return interpret(module, 1).first;
	}
}