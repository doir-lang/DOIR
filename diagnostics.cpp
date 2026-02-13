#define NOMINMAX
#define WIN32_LEAN_AND_MEAN

#include "diagnostics.hpp"
#include "diagnose/diagnostics.hpp"

diagnose::manager& doir::diagnostics() {
	static diagnose::manager diagnostics;
	return diagnostics;
}

diagnose::diagnostic doir::generate_diagnostic(doir::diagnostic_type type, diagnose::source_location::detailed location, std::string_view source, std::string_view path) {
	diagnostics().register_source(path, source);

	diagnose::diagnostic out;
	out.code = (size_t)type;
	out.location = location;
	switch(type){
	// Errors
	break; case diagnostic_type::LanguageChangeNotSupported:
		out.kind = diagnose::diagnostic::error;
		out.message = "Changing languages is not supported in the prototype";
	break; case diagnostic_type::FileDoesNotExist:
		out.kind = diagnose::diagnostic::error;
		out.message = "File does not exist";
	break; case diagnostic_type::NumberingStartsAt1:
		out.kind = diagnose::diagnostic::error;
		out.message = "Numbering starts at 1";
	break; case diagnostic_type::NumberingOutOfOrder:
		out.kind = diagnose::diagnostic::error;
		out.message = "Numbering out of order";
	break; case diagnostic_type::AliasNotAllowed:
		out.kind = diagnose::diagnostic::error;
		out.message = "Alias not allowed";
	break; case diagnostic_type::InvalidIdentifier:
		out.kind = diagnose::diagnostic::error;
		out.message = "Invalid identifier";

	// Warnings
	break; case diagnostic_type::CompilerNamespaceReserved:
		out.kind = diagnose::diagnostic::warning;
		out.message = "`compiler` namespace reserved";
    }
    return out;
}
