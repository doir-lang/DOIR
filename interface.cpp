#define NOMINMAX
#define WIN32_LEAN_AND_MEAN

#include "interface.hpp"
#include "module.hpp"
#include "string_helpers.hpp"

#include <unordered_map>

namespace doir {

	std::vector<ecrs::entity_t> function_inputs::associated_parameters(const module& mod, const doir::block& block) {
		std::vector<ecrs::entity_t> parameters; parameters.reserve(related.size());
		for(size_t i = 0; i < related.size(); ++i)
			for(auto e: block.related)
				if(mod.has_component<doir::function_parameter>(e))
					if(auto& p = mod.get_component<doir::function_parameter>(e); p.index == i) {
						parameters.push_back(e);
						break;
					}

		return parameters;
	}

	std::vector<ecrs::entity_t> lookup::function_inputs::associated_parameters(const module& mod, const doir::block& block) {
		std::vector<ecrs::entity_t> parameters; parameters.reserve(size());
		for(size_t i = 0; i < size(); ++i)
			for(auto e: block.related)
				if(mod.has_component<doir::function_parameter>(e))
					if(auto& p = mod.get_component<doir::function_parameter>(e); p.index == i) {
						parameters.push_back(e);
						break;
					}

		return parameters;
	}

	block_builder block_builder::create(doir::module &mod) {
		block_builder out;
		out.mod = &mod;
		out.block = mod.add_entity();
		mod.add_component<doir::block>(out.block);
		return out;
	}

	ecrs::entity_t block_builder::end() {
		mod = nullptr;
		return std::exchange(block, ecrs::invalid_entity);
	}

	block_builder& block_builder::clear() {
		mod->get_component<doir::block>(block).related.clear();
		return *this;
	}

	ecrs::entity_t push_common(doir::module *mod, ecrs::entity_t block, interned_string name) {
		assert(mod->has_component<doir::block>(block));
		auto out = mod->add_entity();
		if(std::string_view{name} != "_")
			mod->add_component<doir::name>(out) = {name};
		mod->add_component<doir::parent>(out) = {{block}};
		return mod->get_component<doir::block>(block).related.emplace_back(out);
	}

	ecrs::entity_t block_builder::attach_number(doir::module& mod, ecrs::entity_t to, ecrs::entity_t type, long double value) {
		mod.add_component<doir::type_of>(to) = {{type}};
		mod.add_component<doir::number>(to) = {.value = value};
		return to;
	}
	ecrs::entity_t block_builder::push_number(interned_string name, ecrs::entity_t type, long double value) {
		auto out = push_common(mod, block, name);
		return attach_number(*mod, out, type, value);
	}

	ecrs::entity_t block_builder::attach_number(doir::module& mod, ecrs::entity_t to, interned_string type_lookup, long double value) {
		mod.add_component<doir::lookup::type_of>(to) = {{type_lookup}};
		mod.add_component<doir::number>(to) = {.value = value};
		return to;
	}
	ecrs::entity_t block_builder::push_number(interned_string name, interned_string type_lookup, long double value) {
		auto out = push_common(mod, block, name);
		return attach_number(*mod, out, type_lookup, value);
	}

	ecrs::entity_t block_builder::attach_string(doir::module& mod, ecrs::entity_t to, ecrs::entity_t type, interned_string value) {
		mod.add_component<doir::type_of>(to) = {{type}};
		mod.add_component<doir::string>(to) = {.value = value};
		return to;
	}
	ecrs::entity_t block_builder::push_string(interned_string name, ecrs::entity_t type, interned_string value) {
		auto out = push_common(mod, block, name);
		return attach_string(*mod, out, type, value);
	}
	ecrs::entity_t block_builder::attach_string(doir::module& mod, ecrs::entity_t to, interned_string type_lookup, interned_string value) {
		mod.add_component<doir::lookup::type_of>(to) = {{type_lookup}};
		mod.add_component<doir::string>(to) = {.value = value};
		return to;
	}
	ecrs::entity_t block_builder::push_string(interned_string name, interned_string type_lookup, interned_string value) {
		auto out = push_common(mod, block, name);
		return attach_string(*mod, out, type_lookup, value);
	}

	ecrs::entity_t block_builder::attach_valueless(doir::module& mod, ecrs::entity_t to, ecrs::entity_t type) {
		mod.add_component<doir::type_of>(to) = {{type}};
		mod.add_component<doir::flags>(to).flags = doir::flags::Valueless;
		return to;
	}
	ecrs::entity_t block_builder::push_valueless(interned_string name, ecrs::entity_t type) {
		auto out = push_common(mod, block, name);
		return attach_valueless(*mod, out, type);
	}
	ecrs::entity_t block_builder::attach_valueless(doir::module& mod, ecrs::entity_t to, interned_string type_lookup) {
		mod.add_component<doir::lookup::type_of>(to) = {{type_lookup}};
		mod.add_component<doir::flags>(to).flags = doir::flags::Valueless;
		return to;
	}
	ecrs::entity_t block_builder::push_valueless(interned_string name, interned_string type_lookup) {
		auto out = push_common(mod, block, name);
		return attach_valueless(*mod, out, type_lookup);
	}

	#define ATTACH_CALL_BODY(TYPE_OF_TYPE, COMPONENT_TYPE, VECTOR_TYPE,\
						CALL_TYPE, FUNCTION_VALUE, ARGUMENTS)\
		mod.add_component<TYPE_OF_TYPE>(to) = {{type}};\
		(VECTOR_TYPE &)mod.add_component<COMPONENT_TYPE>(to) = {\
			ARGUMENTS.begin(), ARGUMENTS.end()\
		};\
		mod.add_component<CALL_TYPE>(to) = {{FUNCTION_VALUE}};\
		return to;

	ecrs::entity_t block_builder::attach_call(doir::module& mod, ecrs::entity_t to, ecrs::entity_t type, ecrs::entity_t function, std::span<ecrs::entity_t> arguments) {
		ATTACH_CALL_BODY(doir::type_of, doir::function_inputs, std::vector<ecrs::entity_t>, doir::call, function, arguments);
	}
	ecrs::entity_t block_builder::push_call(interned_string name, ecrs::entity_t type, ecrs::entity_t function, std::span<ecrs::entity_t> arguments){
		auto out = push_common(mod, block, name);
		return attach_call(*mod, out, type, function, arguments);
	}

	ecrs::entity_t block_builder::attach_call(doir::module& mod, ecrs::entity_t to, interned_string type, ecrs::entity_t function, std::span<ecrs::entity_t> arguments) {
		ATTACH_CALL_BODY(doir::lookup::type_of, doir::function_inputs, std::vector<ecrs::entity_t>, doir::call, function, arguments);
	}
	ecrs::entity_t block_builder::push_call(interned_string name, interned_string type, ecrs::entity_t function, std::span<ecrs::entity_t> arguments){
		auto out = push_common(mod, block, name);
		return attach_call(*mod, out, type, function, arguments);
	}

	ecrs::entity_t block_builder::attach_call(doir::module& mod, ecrs::entity_t to, ecrs::entity_t type, interned_string function_lookup, std::span<lookup::lookup> arguments) {
		ATTACH_CALL_BODY(doir::type_of, doir::lookup::function_inputs, std::vector<lookup::lookup>, doir::lookup::call, function_lookup, arguments);
	}
	ecrs::entity_t block_builder::push_call(interned_string name, ecrs::entity_t type, interned_string function_lookup, std::span<lookup::lookup> arguments){
		auto out = push_common(mod, block, name);
		return attach_call(*mod, out, type, function_lookup, arguments);
	}

	ecrs::entity_t block_builder::attach_call(doir::module& mod, ecrs::entity_t to, interned_string type, interned_string function_lookup, std::span<lookup::lookup> arguments) {
		ATTACH_CALL_BODY(doir::lookup::type_of, doir::lookup::function_inputs, std::vector<lookup::lookup>, doir::lookup::call, function_lookup, arguments);
	}
	ecrs::entity_t block_builder::push_call(interned_string name, interned_string type, interned_string function_lookup, std::span<lookup::lookup> arguments){
		auto out = push_common(mod, block, name);
		return attach_call(*mod, out, type, function_lookup, arguments);
	}

	ecrs::entity_t block_builder::attach_call(doir::module& mod, ecrs::entity_t to, ecrs::entity_t type, ecrs::entity_t function, std::span<lookup::lookup> arguments) {
		ATTACH_CALL_BODY(doir::type_of, doir::lookup::function_inputs, std::vector<lookup::lookup>, doir::call, function, arguments);
	}
	ecrs::entity_t block_builder::push_call(interned_string name, ecrs::entity_t type, ecrs::entity_t function, std::span<lookup::lookup> arguments){
		auto out = push_common(mod, block, name);
		return attach_call(*mod, out, type, function, arguments);
	}

	ecrs::entity_t block_builder::attach_call(doir::module& mod, ecrs::entity_t to, interned_string type, ecrs::entity_t function, std::span<lookup::lookup> arguments) {
		ATTACH_CALL_BODY(doir::lookup::type_of, doir::lookup::function_inputs, std::vector<lookup::lookup>, doir::call, function, arguments);
	}
	ecrs::entity_t block_builder::push_call(interned_string name, interned_string type, ecrs::entity_t function, std::span<lookup::lookup> arguments) {
		auto out = push_common(mod, block, name);
		return attach_call(*mod, out, type, function, arguments);
	}

	block_builder block_builder::attach_subblock(doir::module& mod, ecrs::entity_t to, ecrs::entity_t type) {
		mod.add_component<doir::type_of>(to) = {{type}};
		mod.add_component<doir::block>(to);
		return {to, &mod};
	}
	block_builder block_builder::push_subblock(interned_string name, ecrs::entity_t type) {
		auto out = push_common(mod, block, name);
		return attach_subblock(*mod, out, type);
	}

	block_builder block_builder::attach_subblock(doir::module& mod, ecrs::entity_t to, interned_string type_lookup) {
		mod.add_component<doir::lookup::type_of>(to) = {{type_lookup}};
		mod.add_component<doir::block>(to);
		return {to, &mod};
	}
	block_builder block_builder::push_subblock(interned_string name, interned_string type_lookup) {
		auto out = push_common(mod, block, name);
		return attach_subblock(*mod, out, type_lookup);
	}

	function_builder block_builder::attach_function(doir::module& mod, ecrs::entity_t to, ecrs::entity_t function_type, bool push_parameters /*= false*/) {
		mod.add_component<doir::type_of>(to) = {{function_type}};
		mod.add_component<doir::block>(to);
		if(mod.has_component<doir::function_return_type>(function_type))
			mod.add_component<doir::function_return_type>(to) = mod.get_component<doir::function_return_type>(function_type);
		else mod.add_component<lookup::function_return_type>(to) = mod.get_component<lookup::function_return_type>(function_type);

		if(!push_parameters) return {to, &mod};

		auto inputs = mod.has_component<doir::function_inputs>(function_type)
			? doir::lookup::function_inputs::to_lookup(mod.get_component<doir::function_inputs>(function_type))
			: mod.get_component<doir::lookup::function_inputs>(function_type);
		std::vector<std::string> names;
		if(mod.has_component<doir::function_parameter_names>(function_type)) {
			auto& param_names = mod.get_component<doir::function_parameter_names>(function_type);
			names = {param_names.begin(), param_names.end()};
		} else {
			names.resize(inputs.size());
			for(size_t i = 0; i < names.size(); ++i)
				names[i] = "a" + std::to_string(i);
		}

		function_builder out = {to, &mod};
		for(size_t i = 0; i < inputs.size(); ++i)
			if(inputs[i].resolved())
				out.push_valueless_parameter(i, mod.interner.intern(names[i]), inputs[i].entity());
			else out.push_valueless_parameter(i, mod.interner.intern(names[i]), inputs[i].name());
		return out;
	}
	function_builder block_builder::push_function(interned_string name, ecrs::entity_t function_type, bool push_parameters /*= false*/) {
		auto out = push_common(mod, block, name);
		return attach_function(*mod, out, function_type, push_parameters);
	}

	ecrs::entity_t block_builder::attach_valueless_function(doir::module& mod, ecrs::entity_t to, ecrs::entity_t function_type) {
		mod.add_component<doir::type_of>(to) = {{function_type}};
		if(mod.has_component<doir::function_return_type>(function_type))
			mod.add_component<doir::function_return_type>(to) = mod.get_component<doir::function_return_type>(function_type);
		else mod.add_component<lookup::function_return_type>(to) = mod.get_component<lookup::function_return_type>(function_type);
		return to;
	}
	ecrs::entity_t block_builder::push_valueless_function(interned_string name, ecrs::entity_t function_type) {
		auto out = push_common(mod, block, name);
		return attach_valueless_function(*mod, out, function_type);
	}

	block_builder block_builder::attach_type(doir::module& mod, ecrs::entity_t to) {
		mod.add_component<doir::type_definition>(to);
		mod.add_component<doir::block>(to);
		return {to, &mod};
	}
	block_builder block_builder::push_type(interned_string name) {
		auto out = push_common(mod, block, name);
		return attach_type(*mod, out);
	}

	ecrs::entity_t block_builder::attach_function_type(doir::module& mod, ecrs::entity_t to, std::span<ecrs::entity_t> argument_types, std::optional<ecrs::entity_t> return_type /*= {}*/, std::span<interned_string> parameter_names /*= {}*/) {
		mod.add_component<type_definition>(to);
		mod.add_component<function_inputs>(to).related = {argument_types.begin(), argument_types.end()};
		if(return_type) mod.add_component<function_return_type>(to).related = {*return_type};
		if(parameter_names.size()) {
			assert(parameter_names.size() == argument_types.size());
			mod.add_component<function_parameter_names>(to) = {{ parameter_names.begin(), parameter_names.end() }};
		}
		return to;
	}
	ecrs::entity_t block_builder::push_function_type(interned_string name, std::span<ecrs::entity_t> argument_types, std::optional<ecrs::entity_t> return_type /*= {}*/, std::span<interned_string> parameter_names /*= {}*/) {
		auto out = push_common(mod, block, name);
		return attach_function_type(*mod, out, argument_types, return_type, parameter_names);
	}

	ecrs::entity_t block_builder::attach_function_type(doir::module& mod, ecrs::entity_t to, std::span<lookup::lookup> parameter_types, std::optional<lookup::lookup> return_type /*= {}*/, std::span<interned_string> parameter_names /*= {}*/) {
		mod.add_component<type_definition>(to);
		mod.add_component<lookup::function_inputs>(to) = {{parameter_types.begin(), parameter_types.end()}};
		if(return_type) mod.add_component<lookup::function_return_type>(to) = {*return_type};
		if(parameter_names.size()) {
			assert(parameter_names.size() == parameter_types.size());
			mod.add_component<function_parameter_names>(to) = {{ parameter_names.begin(), parameter_names.end() }};
		}
		return to;
	}
	ecrs::entity_t block_builder::push_function_type(interned_string name, std::span<lookup::lookup> argument_types, std::optional<lookup::lookup> return_type /*= {}*/, std::span<interned_string> parameter_names /*= {}*/) {
		auto out = push_common(mod, block, name);
		return attach_function_type(*mod, out, argument_types, return_type, parameter_names);
	}

	ecrs::entity_t block_builder::attach_pointer(doir::module& mod, ecrs::entity_t to, ecrs::entity_t base, size_t size /* =0 */) {
		mod.add_component<doir::type_definition>(to);
		mod.add_component<doir::pointer>(to) = {{base}, size};
		return to;
	}
	ecrs::entity_t block_builder::push_pointer(interned_string name, ecrs::entity_t base, size_t size /* =0 */) {
		auto out = push_common(mod, block, name);
		return attach_pointer(*mod, out, base);
	}

	ecrs::entity_t block_builder::attach_alias(doir::module& mod, ecrs::entity_t to, ecrs::entity_t ref) {
		mod.add_component<doir::alias>(to) = {{ref}};
		return to;
	}
	ecrs::entity_t block_builder::push_alias(interned_string name, ecrs::entity_t ref) {
		auto out = push_common(mod, block, name);
		return attach_alias(*mod, out, ref);
	}

	ecrs::entity_t block_builder::attach_alias(doir::module& mod, ecrs::entity_t to, interned_string ref_lookup) {
		mod.add_component<doir::lookup::alias>(to) = {ref_lookup};
		return to;
	}
	ecrs::entity_t block_builder::push_alias(interned_string name, interned_string ref_lookup) {
		auto out = push_common(mod, block, name);
		return attach_alias(*mod, out, ref_lookup);
	}

	block_builder block_builder::attach_namespace(doir::module& mod, ecrs::entity_t to) {
		mod.add_component<doir::flags>(to).flags = doir::flags::Namespace;
		mod.add_component<doir::block>(to);
		return {to, &mod};
	}
	block_builder block_builder::push_namespace(interned_string name) {
		auto out = push_common(mod, block, name);
		return attach_namespace(*mod, out);
	}

	ecrs::entity_t function_builder::attach_number_parameter(doir::module& mod, ecrs::entity_t to, size_t index, ecrs::entity_t type, long double value) {
		mod.add_component<doir::function_parameter>(to) = {index};
		return attach_number(mod, to, type, value);;
	}
	ecrs::entity_t function_builder::push_number_parameter(size_t index, interned_string name, ecrs::entity_t type, long double value) {
		auto out = push_common(mod, block, name);
		return attach_number_parameter(*mod, out, index, type, value);
	}
	ecrs::entity_t function_builder::attach_number_parameter(doir::module& mod, ecrs::entity_t to, size_t index, interned_string type_lookup, long double value) {
		mod.add_component<doir::function_parameter>(to) = {index};
		return attach_number(mod, to, type_lookup, value);;
	}
	ecrs::entity_t function_builder::push_number_parameter(size_t index, interned_string name, interned_string type_lookup, long double value) {
		auto out = push_common(mod, block, name);
		return attach_number_parameter(*mod, out, index, type_lookup, value);
	}
	ecrs::entity_t function_builder::attach_string_parameter(doir::module& mod, ecrs::entity_t to, size_t index, ecrs::entity_t type, interned_string value) {
		mod.add_component<doir::function_parameter>(to) = {index};
		return attach_string(mod, to, type, value);;
	}
	ecrs::entity_t function_builder::push_string_parameter(size_t index, interned_string name, ecrs::entity_t type, interned_string value) {
		auto out = push_common(mod, block, name);
		return attach_string_parameter(*mod, out, index, type, value);
	}
	ecrs::entity_t function_builder::attach_string_parameter(doir::module& mod, ecrs::entity_t to, size_t index, interned_string type_lookup, interned_string value) {
		mod.add_component<doir::function_parameter>(to) = {index};
		return attach_string(mod, to, type_lookup, value);;
	}
	ecrs::entity_t function_builder::push_string_parameter(size_t index, interned_string name, interned_string type_lookup, interned_string value) {
		auto out = push_common(mod, block, name);
		return attach_string_parameter(*mod, out, index, type_lookup, value);
	}
	ecrs::entity_t function_builder::attach_valueless_parameter(doir::module& mod, ecrs::entity_t to, size_t index, ecrs::entity_t type) {
		mod.add_component<doir::function_parameter>(to) = {index};
		return attach_valueless(mod, to, type);;
	}
	ecrs::entity_t function_builder::push_valueless_parameter(size_t index, interned_string name, ecrs::entity_t type) {
		auto out = push_common(mod, block, name);
		return attach_valueless_parameter(*mod, out, index, type);
	}
	ecrs::entity_t function_builder::attach_valueless_parameter(doir::module& mod, ecrs::entity_t to, size_t index, interned_string type_lookup) {
		mod.add_component<doir::function_parameter>(to) = {index};
		return attach_valueless(mod, to, type_lookup);;
	}
	ecrs::entity_t function_builder::push_valueless_parameter(size_t index, interned_string name, interned_string type_lookup) {
		auto out = push_common(mod, block, name);
		return attach_valueless_parameter(*mod, out, index, type_lookup);
	}

} // namespace doir
