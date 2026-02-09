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

struct call_info {
	bool flatten = false, Inline = false, tail = false;
	doir::interned_string function;
	doir::lookup::function_inputs inputs;
};

using assignment_value_t = std::variant<long double, doir::interned_string, call_info, ecrs::entity_t>;

peg::parser doir::initialize_parser(std::vector<doir::block_builder>& blocks, doir::string_interner& interner, bool guarantee_source_location /*= false */) {
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

	// auto ok = parser.load_grammar(grammar);
	// assert(ok);

	auto compiler_interned = interner.intern("compiler");
	auto type_interned = interner.intern("type");
	auto namespace_interned = interner.intern("namespace");
	auto alias_interned = interner.intern("alias");

	parser["assignment"] = [&, guarantee_source_location, compiler_interned, type_interned, namespace_interned, alias_interned](const peg::SemanticValues &vs) {
		bool Export = false;
		if(vs.tokens.size())
			if(vs.token(0) == "export")
				Export = true;

		auto ident = std::any_cast<interned_string>(vs[0 + Export]);
		auto type = vs[3 + Export];
		std::optional<diagnose::source_location::detailed> location = {};
		std::optional<assignment_value_t> value = {};

		auto dbg = vs.size() - Export;
		switch(vs.size() - Export) {
		break; case 7: // valueless
			{ /* do nothing */}
		break; case 9: // sourceinfo
			location = std::any_cast<diagnose::source_location::detailed>(vs[5 + Export]);
		break; case 12: // value and sourceinfo
			location = std::any_cast<diagnose::source_location::detailed>(vs[8 + Export]);
		case 10: // value
			value = std::any_cast<assignment_value_t>(vs[7 + Export]);
		}

		auto invalid_function_type_error = []() {
			// TODO: Implement
		};

		auto& mod = *blocks.back().mod;
		ecrs::entity_t e;
		if(!value) {
			if(type.type() == typeid(doir::lookup::type_of))
				e = blocks.back().push_valueless(ident, std::any_cast<doir::lookup::type_of>(type).name());
			else {/* TODO: implement */}
		} else if(std::holds_alternative<long double>(*value)) {
			if(type.type() == typeid(doir::lookup::type_of))
				e = blocks.back().push_number(ident, std::any_cast<doir::lookup::type_of>(type).name(), std::get<long double>(*value));
			else invalid_function_type_error();
		} else if(std::holds_alternative<interned_string>(*value)) {
			if(type.type() == typeid(doir::lookup::type_of))
				e = blocks.back().push_string(ident, std::any_cast<doir::lookup::type_of>(type).name(), std::get<interned_string>(*value));
			else invalid_function_type_error();
		} else if(std::holds_alternative<call_info>(*value)) {
			auto call = std::get<call_info>(*value);
			if(type.type() == typeid(doir::lookup::type_of))
				e = blocks.back().push_call(ident, std::any_cast<doir::lookup::type_of>(type).name(), call.function, call.inputs);
			else {/* TODO: implement */}

			if(call.Inline || call.flatten || call.tail) {
				auto f = (doir::flags::Inline * call.Inline) | (doir::flags::Flatten * call.flatten) | (doir::flags::Tail * call.tail);
				blocks.back().mod->add_component<doir::flags>(e) = (doir::flags&)f;
			}
		} else if(std::holds_alternative<ecrs::entity_t>(*value)) {
			block_builder builder;
			if(type.type() == typeid(doir::lookup::type_of)) {
				auto type_name = std::any_cast<doir::lookup::type_of>(type).name();
				if(type_name == type_interned)
					builder = blocks.back().push_type(ident);
				else if(type_name == namespace_interned) {
					builder = blocks.back().push_namespace(ident);
					if(ident == compiler_interned) {
						mod.get_component<doir::name>(builder.block) = {interner.intern("compiler_ignored")};
						auto& diag = push_diagnostic(diagnostic_type::CompilerNamespaceReserved, get_location(mod, vs), mod.source, *mod.working_file);
						diag.push_annotation_at_start({
							.message = "Use of reserved "s + doir::ansi::type + "compiler" + diagnose::ansi::reset + " namespace has been ignored",
							.color = doir::ansi::type
						});
						return builder.block;
					}
				} else if(type_name == alias_interned) {
					auto& diag = push_diagnostic(diagnostic_type::AliasNotAllowed, get_location(mod, vs), mod.source, *mod.working_file);
					diag.additional_note = "Aliases aren't allowed to reference blocks";
				} else
					builder = blocks.back().push_subblock(ident, interned_string(type_name));

			} else {/* TODO: implement */}

			e = builder.block;
			auto& src_block = blocks.back().mod->get_component<doir::block>(std::get<ecrs::entity_t>(*value));
			auto& dst_block = blocks.back().mod->get_component<doir::block>(e);
			dst_block.related.insert(dst_block.related.end(), src_block.related.begin(), src_block.related.end());
		}

		if(location) mod.add_component<diagnose::source_location::detailed>(e) = *location;
		else if(guarantee_source_location) mod.add_component<diagnose::source_location>(e) = get_location(*blocks.back().mod, vs);

		if(Export) blocks.back().mod->get_or_add_component<doir::flags>(e) = {doir::flags::Export};
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

	parser["Block"] = [&](const peg::SemanticValues &vs) -> assignment_value_t {
		auto out = blocks.back().block;
		blocks.pop_back();
		return out;
	};

	parser["block_start"] = [&](const peg::SemanticValues &vs) {
		auto mod = blocks.back().mod;
		auto& builder = blocks.emplace_back(mod->add_entity(), mod);
		mod->add_component<doir::block>(builder.block);
	};

	parser["function_call"] = [&](const peg::SemanticValues &vs) -> assignment_value_t {
		bool has_modifier = vs.tokens.size();
		call_info out;
		if(has_modifier) {
			if(vs.token(0) == "flatten")
				out.flatten = true;
			else if(vs.token(0) == "inline")
				out.Inline = true;
			else if(vs.token() == "tail")
				out.tail = true;
		}

		out.function = std::any_cast<interned_string>(vs[0 + has_modifier]);
		for(size_t i = 3 + has_modifier; i < vs.size(); i += 3)
			out.inputs.emplace_back(std::any_cast<interned_string>(vs[i]));

		return out;
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

	parser["Constant"] = [&](const peg::SemanticValues &vs) -> assignment_value_t {
		switch (vs.choice()) {
			break; case 0: case 1:
				if( !(vs.token(0).contains(".") || vs.token(0).contains("e") || vs.token(0).contains("E")) )
					return (long double)std::stoi(vs.token_to_string(0), nullptr, 0);
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
