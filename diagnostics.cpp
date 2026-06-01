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
	break; case diagnostic_type::InvalidType:
		out.kind = diagnose::diagnostic::error;
		out.message = "Invalid type";
	break; case diagnostic_type::InvalidFunctionCall:
		out.kind = diagnose::diagnostic::error;
		out.message = "Invalid function call";
	break; case diagnostic_type::CantStoreInFunctionRegister:
		out.kind = diagnose::diagnostic::error;
		out.message = "Cannot store this value in a function register";
	break; case diagnostic_type::CantCopyRegisters:
		out.kind = diagnose::diagnostic::error;
		out.message = std::string("Cannot directly ") + doir::ansi::info + "copy" + diagnose::ansi::reset + " registers";
	break; case diagnostic_type::StringProcessingError:
		out.kind = diagnose::diagnostic::error;
		out.message = "Failed to process character string";
    break; case diagnostic_type::FailedToResolveLookup:
		out.kind = diagnose::diagnostic::error;
		out.message = "Failed to resolve lookup";

	// Warnings
	break; case diagnostic_type::CompilerNamespaceReserved:
		out.kind = diagnose::diagnostic::warning;
		out.message = "`compiler` namespace reserved";
    }
    return out;
}

std::optional<doir::range> doir::parse_parameter_range(std::string_view text, size_t parameter_index) {
    auto open = text.find('(');
    if(open == std::string_view::npos)
        return std::nullopt;

    std::size_t depth = 0;
    std::size_t current_parameter = 0;

    std::size_t parameter_begin = open + 1;

	// This function supports matching nested parameters for future proofing with doir+
    for(std::size_t i = open + 1; i < text.size(); ++i) {
        char c = text[i];

        switch(c) {
            case '(':
            case '[':
            case '{':
            case '<':
                ++depth;
                break;

            case ')':
                if(depth == 0) {
                    // Final parameter before ')'
                    if(current_parameter == parameter_index) {
                        return range{
                            parameter_begin,
                            i
                        };
                    }

                    return std::nullopt;
                }

                --depth;
                break;

            case ']':
            case '}':
            case '>':
                if(depth > 0)
                    --depth;
                break;

            case ',':
                if(depth == 0) {
                    if(current_parameter == parameter_index) {
                        return range{
                            parameter_begin,
                            i
                        };
                    }

                    ++current_parameter;
                    parameter_begin = i + 1;
                }
                break;
        }
    }

    return std::nullopt;
}