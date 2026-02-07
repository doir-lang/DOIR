#define NOMINMAX
#define WIN32_LEAN_AND_MEAN

#define FP_IMPLEMENTATION
#define ECRS_IMPLEMENTATION
#include "module.hpp"
#include "diagnostics.hpp"
#include "parser.hpp"
#include "interface.hpp"
#include "file_manager.hpp"
#include <variant>

using namespace std::literals;

diagnose::source_location get_location(doir::module& mod, const peg::SemanticValues &vs) {
	diagnose::source_location out;
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

	parser.set_logger([&](size_t line, size_t col, std::string_view msg) {
		auto& mod = *blocks.back().mod;
		auto working_file = mod.working_file.value();
		auto message_segments = diagnose::split(msg, ',');
		diagnostics().register_source(working_file, mod.source);

		diagnose::diagnostic diagnostic;
		diagnostic.kind = diagnose::diagnostic::error;
		diagnostic.message = std::string(message_segments[1].substr(1));
		diagnostic.location = {.file = working_file, .start = {line, col}, .end = {line, col + 1}};

		diagnose::diagnostic::annotation annotation;
		annotation.message = "expecting"s + diagnose::ansi::magenta + std::string(message_segments[2].substr(10));
		annotation.position = diagnostic.location.start;
		diagnostic.annotations.push_back(annotation);
		diagnostics().push(diagnostic);
	});

	parser["assignment"] = [&blocks, garuntee_source_location](const peg::SemanticValues &vs) {
		bool Export = false;
		if(vs.tokens.size())
			if(vs.token(0) == "export")
				Export = true;

		auto ident = std::any_cast<interned_string>(vs[0 + Export]);
		auto type = vs[3 + Export];
		std::optional<diagnose::source_location::detailed> location = {};
		std::optional<std::variant<long double, interned_string>> value = {};

		auto dbg = vs.size() - Export;
		switch(vs.size() - Export) {
		break; case 7: // valueless
			{ /* do nothing */}
		break; case 9: // sourceinfo
			location = std::any_cast<diagnose::source_location::detailed>(vs[5 + Export]);
		break; case 12: // value and sourceinfo
			location = std::any_cast<diagnose::source_location::detailed>(vs[8 + Export]);
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

		if(location) mod.add_component<diagnose::source_location::detailed>(e) = *location;
		else if(garuntee_source_location) mod.add_component<diagnose::source_location>(e) = get_location(*blocks.back().mod, vs);

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
		diagnose::source_location::detailed out;
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

		auto& mod = *blocks.back().mod;
		if(out.end.line < out.start.line || out.end.column < out.start.column) {
			auto& diag = push_diagnostic(diagnostic_type::NumberingOutOfOrder, get_location(mod, vs), mod.source, *mod.working_file);
			auto offset = vs.sv().find(":");
			if( !(out.end.line < out.start.line) ) offset = vs.sv().find(":", offset + 1);
			diag.push_annotation({
				.position = {diag.location.start.line, diag.location.start.column + offset + 1},
				.message = "The "s + doir::ansi::info + "start" + diagnose::ansi::reset + " of a source location must come before its " + doir::ansi::info + "end" + diagnose::ansi::reset,
				.color = doir::ansi::info
			});
		}

		if(out.start.column == 0 && out.end.column == 1 && out.start.line != 0) try {
			std::vector<std::string_view> lines = diagnose::split(doir::file_manager::singleton().get_file_string(out.file), '\n');

			out.start.column = 1;
			out.end.column = lines[out.start.line - 1].size() + 1;
		} catch(std::system_error) {
			auto& diag = push_diagnostic(diagnostic_type::FileDoesNotExist, get_location(mod, vs), mod.source, *mod.working_file);
			diag.push_annotation_at_start({
				.message = "Attempted to load file "s + doir::ansi::file + "`" + std::string(out.file) + "`" + diagnose::ansi::reset,
				.color = doir::ansi::file,
			});
			diag.additional_note = "Calculating the end of line with column=0 requires loading a file and scanning its lines.";

		} else if(out.start.column == 0 || out.start.line == 0) {
			auto& diag = push_diagnostic(diagnostic_type::NumberingStartsAt1, get_location(mod, vs), mod.source, *mod.working_file);
			bool line = out.start.line == 0;
			auto offset = vs.sv().find(":");
			if(!line) offset = vs.sv().find(":", offset + 1);
			diag.push_annotation({
				.position = {diag.location.start.line, diag.location.start.column + offset + 1},
				.message = std::string("Source location ") + doir::ansi::info + (line ? "lines" : "columns") + diagnose::ansi::reset + " start at 0, not 1",
				.color = doir::ansi::info,
			});
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
