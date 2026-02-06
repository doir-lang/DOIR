#include "interface.hpp"
#include "module.hpp"
#include "string_helpers.hpp"

namespace doir {
	block_builder block_builder::create(doir::module& mod) {
		block_builder out;
		out.mod = &mod;
		out.block = mod.add_entity();
		mod.add_component<doir::block>(out.block);
		return out;
	}

	ecrs::entity_t push_common(doir::module* mod, ecrs::entity_t block, interned_string name, ecrs::entity_t type){
		auto out = mod->add_entity();
		mod->add_component<doir::name>(out) = {name};
		mod->add_component<doir::type_of>(out) = {{type}};
		return mod->get_component<doir::block>(block).related.emplace_back(out);;
	}

	ecrs::entity_t push_common_lookup(doir::module* mod, ecrs::entity_t block, interned_string name, interned_string type_lookup){
		auto out = mod->add_entity();
		mod->add_component<doir::name>(out) = {name};
		mod->add_component<doir::lookup::type_of>(out) = {{type_lookup}};
		return mod->get_component<doir::block>(block).related.emplace_back(out);;
	}

	ecrs::entity_t block_builder::push_number(interned_string name, ecrs::entity_t type, long double value){
		auto out = push_common(mod, block, name, type);
		mod->add_component<doir::number>(out) = {.value = value};
		return out;
	}
	ecrs::entity_t block_builder::push_number(interned_string name, interned_string type_lookup, long double value){
		auto out = push_common_lookup(mod, block, name, type_lookup);
		mod->add_component<doir::number>(out) = {.value = value};
		return out;
	}

	ecrs::entity_t block_builder::push_string(interned_string name, ecrs::entity_t type, interned_string value){
		auto out = push_common(mod, block, name, type);
		mod->add_component<doir::string>(out) = {.value = value};
		return out;
	}
	ecrs::entity_t block_builder::push_string(interned_string name, interned_string type_lookup, interned_string value){
		auto out = push_common_lookup(mod, block, name, type_lookup);
		mod->add_component<doir::string>(out) = {.value = value};
		return out;
	}

	ecrs::entity_t block_builder::push_valueless(interned_string name, ecrs::entity_t type){
		auto out = push_common(mod, block, name, type);
		mod->add_component<valueless>(out);
		return out;
	}
	ecrs::entity_t block_builder::push_valueless(interned_string name, interned_string type_lookup){
		auto out = push_common_lookup(mod, block, name, type_lookup);
		mod->add_component<valueless>(out);
		return out;
	}
}
