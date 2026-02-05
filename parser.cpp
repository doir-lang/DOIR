#define FP_IMPLEMENTATION
#define ECRS_IMPLEMENTATION
#include "parser.hpp"
#include "interface.hpp"
#include "module.hpp"
#include <variant>

peg::parser doir::initialize_parser(std::vector<doir::block_builder>& blocks, doir::string_interner& interner) {
	auto grammar =
#include "grammar.peg"
	;
	peg::parser parser(grammar);

	parser["assignment"] = [&blocks](const peg::SemanticValues &vs) {
		bool Export = false;
		if(vs.tokens.size())
			if(vs.token(0) == "export")
				Export = true;

		auto ident = std::any_cast<interned_string>(vs[0 + Export]);
		auto type = vs[3 + Export];
		std::optional<source_location> location = {};
		std::optional<std::variant<long double, interned_string>> value = {};

		auto dbg = vs.size() - Export;
		switch(vs.size() - Export) {
		break; case 7: // valueless
			{ /* do nothing */}
		break; case 9: // sourceinfo
			// location = std::any_cast<source_location>(vs[5 + Export]);
		break; case 12: // value and sourceinfo
			// location = std::any_cast<source_location>(vs[8 + Export]);
		case 10: // value
			value = std::any_cast<std::variant<long double, interned_string>>(vs[7 + Export]);

		}

		// if(!location) // TODO: Calculate the location in the current input

		ecrs::entity_t e;
		if(!value) {
			if(type.type() == typeid(doir::lookup::type_of))
				e = blocks.back().push_valueless(ident, std::any_cast<doir::lookup::type_of>(type).name(), location);
		} else if(std::holds_alternative<long double>(*value)) {
			if(type.type() == typeid(doir::lookup::type_of))
				e = blocks.back().push_number(ident, std::any_cast<doir::lookup::type_of>(type).name(), std::get<long double>(*value), location);
		} else if(std::holds_alternative<interned_string>(*value))
			if(type.type() == typeid(doir::lookup::type_of))
				e = blocks.back().push_string(ident, std::any_cast<doir::lookup::type_of>(type).name(), std::get<interned_string>(*value), location);

		if(Export) blocks.back().mod->add_component<doir::flags>(e) = {doir::flags::Export};
		return e;
	};

	parser["Type"] = [](const peg::SemanticValues &vs) -> std::any {
		switch(vs.choice()) {
		break; case 0: // FunctionType
			throw std::runtime_error("TODO: Implement");
		break; case 1: { // Identifier
			auto ident = std::any_cast<interned_string>(vs[0]);
			return doir::lookup::type_of(ident);
		}
		}
		throw std::runtime_error("Type Unreachable");
	};

	parser["Identifier"] = [&](const peg::SemanticValues &vs) {
		return interner.intern(vs.token(0));
	};

	parser["Constant"] = [&](const peg::SemanticValues &vs) -> std::variant<long double, interned_string> {
		switch (vs.choice()) {
			break; case 0: case 1:
				return vs.token_to_number<long double>();
			break; case 2: case 3: {
				auto unescaped = unescape_python_string(vs.token(0));
				return interner.intern(unescaped);
			}
		}
		throw std::runtime_error("Constant Unreachable");
	};

	return parser;
};
