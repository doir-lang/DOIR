#define NOMINMAX
#define WIN32_LEAN_AND_MEAN 

#define FP_IMPLEMENTATION
#define ECRS_IMPLEMENTATION
#include "module.hpp"
#include "parser.hpp"
#include "interface.hpp"
#include "file_manager.hpp"
#include <variant>

doir::source_location get_location(doir::module& mod, const peg::SemanticValues &vs) {
	doir::source_location out;
	auto sv = vs.sv();
	out.file = vs.path;
	out.start_byte = sv.data() - mod.source.data();
	out.end_byte = out.start_byte + sv.size() - 1;
	return out;
}

peg::parser doir::initialize_parser(std::vector<doir::block_builder>& blocks, doir::string_interner& interner, bool garuntee_source_location /*= false */) {
	auto grammar =
#include "grammar.peg"
	;
	peg::parser parser(grammar);

	// parser.set_logger([](size_t line, size_t col, std::string_view msg, std::string_view rule) {
	//   std::cerr << line << ":" << col << ": " << msg << "\n";
	// });

	parser["assignment"] = [&blocks, garuntee_source_location](const peg::SemanticValues &vs) {
		bool Export = false;
		if(vs.tokens.size())
			if(vs.token(0) == "export")
				Export = true;

		auto ident = std::any_cast<interned_string>(vs[0 + Export]);
		auto type = vs[3 + Export];
		std::optional<source_location::detailed> location = {};
		std::optional<std::variant<long double, interned_string>> value = {};

		auto dbg = vs.size() - Export;
		switch(vs.size() - Export) {
		break; case 7: // valueless
			{ /* do nothing */}
		break; case 9: // sourceinfo
			location = std::any_cast<source_location::detailed>(vs[5 + Export]);
		break; case 12: // value and sourceinfo
			location = std::any_cast<source_location::detailed>(vs[8 + Export]);
		case 10: // value
			value = std::any_cast<std::variant<long double, interned_string>>(vs[7 + Export]);

		}

		auto& mod = *blocks.back().mod;
		ecrs::entity_t e;
		if(!value) {
			if(type.type() == typeid(doir::lookup::type_of))
				e = blocks.back().push_valueless(ident, std::any_cast<doir::lookup::type_of>(type).name());
		} else if(std::holds_alternative<long double>(*value)) {
			if(type.type() == typeid(doir::lookup::type_of))
				e = blocks.back().push_number(ident, std::any_cast<doir::lookup::type_of>(type).name(), std::get<long double>(*value));
		} else if(std::holds_alternative<interned_string>(*value))
			if(type.type() == typeid(doir::lookup::type_of))
				e = blocks.back().push_string(ident, std::any_cast<doir::lookup::type_of>(type).name(), std::get<interned_string>(*value));

		if(location) mod.add_component<source_location::detailed>(e) = *location;
		else if(garuntee_source_location) mod.add_component<source_location>(e) = get_location(*blocks.back().mod, vs);

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

	parser["SourceInfo"] = [&](const peg::SemanticValues &vs) {
		source_location::detailed out;
		out.file = vs.token(0);
		out.start.line = peg::token_to_number_<size_t>(vs.token(1));
		switch (vs.tokens.size()) {
		break; case 3: // no ends
			out.end.line = out.start.line;
			out.start.column = peg::token_to_number_<size_t>(vs.token(2));
			out.end.column = out.start.column + 1;
		break; case 4: // line end or column end
			if(vs.token(2).starts_with("-")) { // end line
				out.end.line = peg::token_to_number_<size_t>(vs.token(2).substr(1));
				out.start.column = peg::token_to_number_<size_t>(vs.token(3));
				out.end.column = out.start.column + 1;
			} else { // end column
				out.end.line = out.start.line;
				out.start.column = peg::token_to_number_<size_t>(vs.token(2));
				out.end.column = peg::token_to_number_<size_t>(vs.token(3).substr(1));
			}
		break; case 5: // line end and column end
			out.end.line = peg::token_to_number_<size_t>(vs.token(2).substr(1));
			out.start.column = peg::token_to_number_<size_t>(vs.token(3));
			out.end.column = peg::token_to_number_<size_t>(vs.token(4).substr(1));
		}

		if(out.start.column == 0 && out.end.column == 1) {
			auto lines = split(doir::file_manager::singleton().get_file_string(out.file), '\n');
			out.start.column = 1;
			out.end.column = lines[out.start.line - 1].size() + 1;
		} else if(out.start.column == 0 || out.start.line == 0) {
			// TODO: Error indicating that file numbering starts at 1 not zero!
		}

		return out;
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
