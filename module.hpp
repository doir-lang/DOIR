#pragma once

#include "interface.hpp"
#include "libecrs/context.hpp"
#include "string_helpers.hpp"
#include <string_view>

namespace peg {
	struct parser;
}

namespace doir {
	struct module : public ecrs::context {
		std::string_view source;
		std::optional<std::string_view> working_file = {};
		string_interner interner;

		bool parse(peg::parser& parser, std::string_view source, std::string_view path = "generated.doir");
		bool parse_file(peg::parser& parser, std::string_view path);

		bool flags_set(ecrs::entity_t e, doir::flags::impl check) {
			return flags_set(e, (decltype(doir::flags{}.as_underlying()))check);
		}
		bool flags_set(ecrs::entity_t e, decltype(doir::flags{}.as_underlying()) check);

		void substitute_entities(ecrs::entity_t range, const std::unordered_map<ecrs::entity_t, ecrs::entity_t>& substitutions, size_t max_depth = -1);
	};
}
