#define NOMINMAX
#define WIN32_LEAN_AND_MEAN

#include "interface.hpp"
#include "module.hpp"
#include "string_helpers.hpp"

namespace doir {
	block_builder block_builder::create(doir::module &mod) {
		block_builder out;
		out.mod = &mod;
		out.block = mod.add_entity();
		mod.add_component<doir::block>(out.block);
		return out;
	}

	ecrs::entity_t push_common(doir::module *mod, ecrs::entity_t block, interned_string name) {
		auto out = mod->add_entity();
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
							 FUNCTION_VALUE, ARGUMENTS)\
		auto out = push_common(mod, block, name);\
		mod->add_component<TYPE_OF_TYPE>(out) = {{type}};\
		auto &r = (VECTOR_TYPE &)mod->add_component<COMPONENT_TYPE>(out) = {\
			ARGUMENTS.begin(), ARGUMENTS.end()\
		};\
		r.insert(r.begin(), FUNCTION_VALUE);\
		return out;

	ecrs::entity_t block_builder::push_call(interned_string name, ecrs::entity_t type, ecrs::entity_t function, std::span<ecrs::entity_t> arguments){
		PUSH_CALL_BODY(doir::type_of, function_inputs, std::vector<ecrs::entity_t>, function, arguments);
	}

	ecrs::entity_t block_builder::push_call(interned_string name, interned_string type, ecrs::entity_t function, std::span<ecrs::entity_t> arguments){
		PUSH_CALL_BODY(doir::lookup::type_of, function_inputs, std::vector<ecrs::entity_t>, function, arguments);
	}

	ecrs::entity_t block_builder::push_call(interned_string name, ecrs::entity_t type, interned_string function_lookup, std::span<lookup::lookup> arguments){
		PUSH_CALL_BODY(doir::type_of, lookup::function_inputs, std::vector<lookup::lookup>, function_lookup, arguments);
	}

	ecrs::entity_t block_builder::push_call(interned_string name, interned_string type, interned_string function_lookup, std::span<lookup::lookup> arguments){
		PUSH_CALL_BODY(doir::lookup::type_of, lookup::function_inputs, std::vector<lookup::lookup>, function_lookup, arguments);
	}

	ecrs::entity_t block_builder::push_call(interned_string name, ecrs::entity_t type, ecrs::entity_t function, std::span<lookup::lookup> arguments){
		PUSH_CALL_BODY(doir::type_of, lookup::function_inputs, std::vector<lookup::lookup>, function, arguments);
	}

	ecrs::entity_t block_builder::push_call(interned_string name, interned_string type, ecrs::entity_t function, std::span<lookup::lookup> arguments) {
		PUSH_CALL_BODY(doir::lookup::type_of, lookup::function_inputs, std::vector<lookup::lookup>, function, arguments);
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

	block_builder block_builder::push_type(interned_string name) {
		auto out = push_common(mod, block, name);
		mod->add_component<doir::type_definition>(out);
		mod->add_component<doir::block>(out);
		return {out, mod};
	}

	block_builder block_builder::push_namespace(interned_string name) {
		auto out = push_common(mod, block, name);
		mod->add_component<doir::Namespace>(out);
		mod->add_component<doir::block>(out);
		return {out, mod};
	}

} // namespace doir
