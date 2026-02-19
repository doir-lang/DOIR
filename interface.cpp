#include "fp/dynarray.hpp"
#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#define FP_OSTREAM_SUPPORT

#include "interface.hpp"
#include "module.hpp"
#include "string_helpers.hpp"

#include <unordered_map>

namespace doir {

	fp::raii::dynarray<ecrs::entity_t> function_inputs::associated_parameters(const module& mod, const doir::block& block) {
		fp::raii::dynarray<ecrs::entity_t> parameters; parameters.reserve(related.size());
		for(size_t i = 0; i < related.size(); ++i)
			for(auto e: block.related)
				if(mod.has_component<doir::function_parameter>(e))
					if(auto& p = mod.get_component<doir::function_parameter>(e); p.index == i) {
						parameters.push_back(e);
						break;
					}

		return parameters;
	}

	fp::raii::dynarray<ecrs::entity_t> lookup::function_inputs::associated_parameters(const module& mod, const doir::block& block) {
		fp::raii::dynarray<ecrs::entity_t> parameters; parameters.reserve(size());
		for(size_t i = 0; i < size(); ++i)
			for(auto e: block.related)
				if(mod.has_component<doir::function_parameter>(e))
					if(auto& p = mod.get_component<doir::function_parameter>(e); p.index == i) {
						parameters.push_back(e);
						break;
					}

		return parameters;
	}

	ecrs::entity_t make_function_type(doir::module &mod, fp::view<ecrs::entity_t> argument_types, std::optional<ecrs::entity_t> return_type /*= {} */) {
		auto out = mod.add_entity();
		mod.add_component<type_definition>(out);
		mod.add_component<function_inputs>(out).related = {argument_types.begin(), argument_types.end()};
		if(return_type) mod.add_component<function_return_type>(out).related = {*return_type};
		return out;
	}
	ecrs::entity_t make_function_type(doir::module &mod, fp::view<lookup::lookup> argument_types, std::optional<lookup::lookup> return_type /*= {} */) {
		auto out = mod.add_entity();
		mod.add_component<type_definition>(out);
		mod.add_component<lookup::function_inputs>(out) = {fp::raii::dynarray<lookup::lookup>(argument_types.make_dynamic())};
		if(return_type) mod.add_component<lookup::function_return_type>(out) = {*return_type};
		return out;
	}

	block_builder block_builder::create(doir::module &mod) {
		block_builder out;
		out.mod = &mod;
		out.block = mod.add_entity();
		mod.add_component<doir::block>(out.block);
		return out;
	}

	ecrs::entity_t push_common(doir::module *mod, ecrs::entity_t block, interned_string name) {
		auto out = mod->add_entity();
		if(fp::string::view{name} != "_")
			mod->add_component<doir::name>(out) = {name};
		return mod->get_component<doir::block>(block).related.emplace_back(out);
	}

	ecrs::entity_t block_builder::push_number(interned_string name, ecrs::entity_t type, long double value) {
		auto out = push_common(mod, block, name);
		mod->add_component<doir::type_of>(out) = {{type}};
		mod->add_component<doir::number>(out) = {.value = value};
		return out;
	}
	ecrs::entity_t block_builder::push_number(interned_string name, interned_string type_lookup, long double value) {
		auto out = push_common(mod, block, name);
		mod->add_component<doir::lookup::type_of>(out) = {{type_lookup}};
		mod->add_component<doir::number>(out) = {.value = value};
		return out;
	}

	ecrs::entity_t block_builder::push_string(interned_string name, ecrs::entity_t type, interned_string value) {
		auto out = push_common(mod, block, name);
		mod->add_component<doir::type_of>(out) = {{type}};
		mod->add_component<doir::string>(out) = {.value = value};
		return out;
	}
	ecrs::entity_t block_builder::push_string(interned_string name, interned_string type_lookup, interned_string value) {
		auto out = push_common(mod, block, name);
		mod->add_component<doir::lookup::type_of>(out) = {{type_lookup}};
		mod->add_component<doir::string>(out) = {.value = value};
		return out;
	}

	ecrs::entity_t block_builder::push_valueless(interned_string name, ecrs::entity_t type) {
		auto out = push_common(mod, block, name);
		mod->add_component<doir::type_of>(out) = {{type}};
		mod->add_component<valueless>(out);
		return out;
	}
	ecrs::entity_t block_builder::push_valueless(interned_string name, interned_string type_lookup) {
		auto out = push_common(mod, block, name);
		mod->add_component<doir::lookup::type_of>(out) = {{type_lookup}};
		mod->add_component<valueless>(out);
		return out;
	}

	#define PUSH_CALL_BODY(TYPE_OF_TYPE, COMPONENT_TYPE, VECTOR_TYPE,\
						CALL_TYPE, FUNCTION_VALUE, ARGUMENTS)\
		auto out = push_common(mod, block, name);\
		mod->add_component<TYPE_OF_TYPE>(out) = {{type}};\
		(VECTOR_TYPE &)mod->add_component<COMPONENT_TYPE>(out)\
			= VECTOR_TYPE(ARGUMENTS.make_dynamic());\
		mod->add_component<CALL_TYPE>(out) = {{FUNCTION_VALUE}};\
		return out;

	ecrs::entity_t block_builder::push_call(interned_string name, ecrs::entity_t type, ecrs::entity_t function, fp::view<ecrs::entity_t> arguments){
		PUSH_CALL_BODY(doir::type_of, doir::function_inputs, fp::raii::dynarray<ecrs::entity_t>, doir::call, function, arguments);
	}

	ecrs::entity_t block_builder::push_call(interned_string name, interned_string type, ecrs::entity_t function, fp::view<ecrs::entity_t> arguments){
		PUSH_CALL_BODY(doir::lookup::type_of, doir::function_inputs, fp::raii::dynarray<ecrs::entity_t>, doir::call, function, arguments);
	}

	ecrs::entity_t block_builder::push_call(interned_string name, ecrs::entity_t type, interned_string function_lookup, fp::view<lookup::lookup> arguments){
		PUSH_CALL_BODY(doir::type_of, doir::lookup::function_inputs, fp::raii::dynarray<lookup::lookup>, doir::lookup::call, function_lookup, arguments);
	}

	ecrs::entity_t block_builder::push_call(interned_string name, interned_string type, interned_string function_lookup, fp::view<lookup::lookup> arguments){
		PUSH_CALL_BODY(doir::lookup::type_of, doir::lookup::function_inputs, fp::raii::dynarray<lookup::lookup>, doir::lookup::call, function_lookup, arguments);
	}

	ecrs::entity_t block_builder::push_call(interned_string name, ecrs::entity_t type, ecrs::entity_t function, fp::view<lookup::lookup> arguments){
		PUSH_CALL_BODY(doir::type_of, doir::lookup::function_inputs, fp::raii::dynarray<lookup::lookup>, doir::call, function, arguments);
	}

	ecrs::entity_t block_builder::push_call(interned_string name, interned_string type, ecrs::entity_t function, fp::view<lookup::lookup> arguments) {
		PUSH_CALL_BODY(doir::lookup::type_of, doir::lookup::function_inputs, fp::raii::dynarray<lookup::lookup>, doir::call, function, arguments);
	}

	block_builder block_builder::push_subblock(interned_string name, ecrs::entity_t type) {
		auto out = push_common(mod, block, name);
		mod->add_component<doir::type_of>(out) = {{type}};
		mod->add_component<doir::block>(out);
		return {out, mod};
	}

	block_builder block_builder::push_subblock(interned_string name, interned_string type_lookup) {
		auto out = push_common(mod, block, name);
		mod->add_component<doir::lookup::type_of>(out) = {{type_lookup}};
		mod->add_component<doir::block>(out);
		return {out, mod};
	}

	function_builder block_builder::push_function(interned_string name, ecrs::entity_t function_type) {
		auto out = push_common(mod, block, name);
		mod->add_component<doir::type_of>(out) = {{function_type}};
		mod->add_component<doir::block>(out);
		if(mod->has_component<doir::function_return_type>(function_type))
			mod->add_component<doir::function_return_type>(out) = mod->get_component<doir::function_return_type>(function_type);
		else mod->add_component<lookup::function_return_type>(out) = mod->get_component<lookup::function_return_type>(function_type);
		return {out, mod};
	}
	ecrs::entity_t block_builder::push_valueless_function(interned_string name, ecrs::entity_t function_type) {
		auto out = push_common(mod, block, name);
		mod->add_component<doir::type_of>(out) = {{function_type}};
		if(mod->has_component<doir::function_return_type>(function_type))
			mod->add_component<doir::function_return_type>(out) = mod->get_component<doir::function_return_type>(function_type);
		else mod->add_component<lookup::function_return_type>(out) = mod->get_component<lookup::function_return_type>(function_type);
		return out;
	}

	block_builder block_builder::push_type(interned_string name) {
		auto out = push_common(mod, block, name);
		mod->add_component<doir::type_definition>(out);
		mod->add_component<doir::block>(out);
		return {out, mod};
	}

	ecrs::entity_t block_builder::push_alias(interned_string name, ecrs::entity_t ref) {
		auto out = push_common(mod, block, name);
		mod->add_component<doir::alias>(out) = {{ref}};
		return out;
	}
	ecrs::entity_t block_builder::push_alias(interned_string name, interned_string ref_lookup) {
		auto out = push_common(mod, block, name);
		mod->add_component<doir::lookup::alias>(out) = {ref_lookup};
		return out;
	}

	block_builder block_builder::push_namespace(interned_string name) {
		auto out = push_common(mod, block, name);
		mod->add_component<doir::Namespace>(out);
		mod->add_component<doir::block>(out);
		return {out, mod};
	}

	ecrs::entity_t function_builder::push_number_parameter(size_t index, interned_string name, ecrs::entity_t type, long double value) {
		auto out = push_number(name, type, value);
		mod->add_component<doir::function_parameter>(out) = {index};
		return out;
	}
	ecrs::entity_t function_builder::push_number_parameter(size_t index, interned_string name, interned_string type_lookup, long double value) {
		auto out = push_number(name, type_lookup, value);
		mod->add_component<doir::function_parameter>(out) = {index};
		return out;
	}
	ecrs::entity_t function_builder::push_string_parameter(size_t index, interned_string name, ecrs::entity_t type, interned_string value) {
		auto out = push_string(name, type, value);
		mod->add_component<doir::function_parameter>(out) = {index};
		return out;
	}
	ecrs::entity_t function_builder::push_string_parameter(size_t index, interned_string name, interned_string type_lookup, interned_string value) {
		auto out = push_string(name, type_lookup, value);
		mod->add_component<doir::function_parameter>(out) = {index};
		return out;
	}
	ecrs::entity_t function_builder::push_valueless_parameter(size_t index, interned_string name, ecrs::entity_t type) {
		auto out = push_valueless(name, type);
		mod->add_component<doir::function_parameter>(out) = {index};
		return out;
	}
	ecrs::entity_t function_builder::push_valueless_parameter(size_t index, interned_string name, interned_string type_lookup) {
		auto out = push_valueless(name, type_lookup);
		mod->add_component<doir::function_parameter>(out) = {index};
		return out;
	}

} // namespace doir
