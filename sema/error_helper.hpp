#pragma once
#include "../diagnostics.hpp"

#define EXPECTS_X_INPUTS(name, X)\
	auto& diag = push_diagnostic(doir::diagnostic_type::InvalidFunctionCall, doir::find_detailed_source_location(mod, subtree), mod.source, mod.working_file.value_or(invalid_file_name));\
	diagnose::diagnostic::annotation annotation;\
	annotation.message = std::string(doir::ansi::function) + name + diagnose::ansi::reset + " expects " X " inputs";\
	annotation.position = diag.location.start;\
	diag.annotations.push_back(annotation)

#define PARAMETER_ERROR(name, i, msg)\
	auto location = doir::find_source_location(mod, subtree);\
	auto& diag = push_diagnostic(doir::diagnostic_type::InvalidFunctionCall, location, mod.source, mod.working_file.value_or(invalid_file_name));\
	diagnose::diagnostic::annotation annotation;\
	annotation.message = std::string(doir::ansi::function) + name + diagnose::ansi::reset + " parameter "\
		+ doir::ansi::info + std::to_string(i + 1) + diagnose::ansi::reset + msg;\
	\
	auto range = parse_parameter_range(mod.source.substr(location.start_byte, location.end_byte - location.start_byte), i);\
	if(range) \
		location.start_byte += (range->start + range->end) / 2;\
	annotation.position = location.start(mod.source);\
	diag.annotations.push_back(annotation)

#define NO_ASSOCIATED_REGISTER()\
	auto& diag = push_diagnostic(doir::diagnostic_type::InvalidFunctionCall, doir::find_detailed_source_location(mod, subtree), mod.source, mod.working_file.value_or(invalid_file_name));\
	diagnose::diagnostic::annotation annotation;\
	annotation.message = "Entity " + std::string(doir::ansi::info) + std::to_string(target) + diagnose::ansi::reset + " doesn't have an associated register";\
	annotation.position = diag.location.start;\
	diag.annotations.push_back(annotation)
