#pragma once
#define FP_OSTREAM_SUPPORT

#include <diagnose/diagnostics.hpp>
#include <fp/string.hpp>

namespace doir {
	diagnose::manager& diagnostics();

	struct ansi {
		constexpr static const char* info = diagnose::manager::get_kind_color(diagnose::diagnostic::info);
		constexpr static const char* file = diagnose::ansi::magenta;
		constexpr static const char* type = diagnose::ansi::cyan;
	};

	enum class diagnostic_type {
		Invalid,

		// Errors
		LanguageChangeNotSupported,
		FileDoesNotExist,
		NumberingStartsAt1,
		NumberingOutOfOrder,
		AliasNotAllowed,
		InvalidIdentifier,

		// Warnings
		CompilerNamespaceReserved,
	};

	diagnose::diagnostic generate_diagnostic(diagnostic_type type, diagnose::source_location::detailed location, fp::string::view source, fp::string::view path);
	inline diagnose::diagnostic generate_diagnostic(diagnostic_type type, diagnose::source_location location, fp::string::view source, fp::string::view path) {
		return generate_diagnostic(type, location.to_detailed(source.to_std()), source, path);
	}

	inline diagnose::diagnostic& push_diagnostic(diagnostic_type type, diagnose::source_location::detailed location, fp::string::view source, fp::string::view path) {
		return diagnostics().push(generate_diagnostic(type, location, source, path));
	}
	inline diagnose::diagnostic& push_diagnostic(diagnostic_type type, diagnose::source_location location, fp::string::view source, fp::string::view path){
		return diagnostics().push(generate_diagnostic(type, location, source, path));
	}

}
