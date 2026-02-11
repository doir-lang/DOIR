#pragma once

#include "libecrs/relation.hpp"
#include "string_helpers.hpp"
#include <diagnose/source_location.hpp>
#include <optional>
#include <string_view>
#include <variant>

namespace ecrs {
	using entity_t = uint32_t;
}

namespace doir {

	struct module;

	// Tags
	struct flags {
		enum impl : uint8_t {
			Export = (1 << 1),
			Comptime = (1 << 2), // On a function implies that the function can access the emitter object
			Constant = (1 << 3),
			Pure = (1 << 4),
			Inline = (1 << 5),
			Flatten = (1 << 6),
			Tail = (1 << 7),
		} flags;

		inline bool export_set() const { return flags & Export; }
		inline bool comptime_set() const { return flags & Comptime; }
		inline bool constant_set() const { return flags & Constant; }
		inline bool pure_set() const { return flags & Pure; }
		inline bool inline_set() const { return flags & Inline; }
		inline bool flatten_set() const { return flags & Flatten; }
		inline bool tail_set() const { return flags & Tail; }
	};

	struct valueless {}; // Represents undefined values and external functions/aliases
	struct Namespace {}; // On a type element indicates that the namespace should be inherited

	struct pointer { size_t size = 0; }; // Size == 0 implies no bounds information

	struct name : public interned_string {};

	struct function_return_type : public ecrs::relation<1> {};  // Also expects function_inputs and block/valueless attached
	struct function_inputs : public ecrs::relation<> {}; // In a call the first input is the function to call
	struct function_parameter {
		size_t index; // Increments to indicate the order of the parameters
	};

	struct block : public ecrs::relation<> {}; // When alone (no type_of etc...) represents a quoted block

	struct type_definition { // Also expects block attached
		size_t size, align;
	};

	struct alias : public ecrs::relation<1> { // Can be INVALID if a valueless is attached
		std::optional<std::string_view> file = {}; // Aliases can reference other files
	};

	struct type_of : public ecrs::relation<1> {}; // Expects a number, string, valueless, or block attached

	struct number {
		long double value; // TODO: should use bigint rational instead?
	};

	struct string {
		interned_string value;
	};

	struct call : public ecrs::relation<1> {}; // Also expects function_inputs attached

	namespace lookup {
		struct lookup : public std::variant<ecrs::entity_t, interned_string> {
			using super = std::variant<ecrs::entity_t, interned_string>;
			using super::super;
			using super::operator=;

			bool resolved() const { return std::holds_alternative<ecrs::entity_t>(*this); }
			ecrs::entity_t& entity() { return std::get<ecrs::entity_t>(*this); }
			const ecrs::entity_t& entity() const { return std::get<ecrs::entity_t>(*this); }
			interned_string& name() { return std::get<interned_string>(*this); }
			const interned_string& name() const { return std::get<interned_string>(*this); }
		};
		struct function_return_type : public lookup {};
		struct function_inputs : public std::vector<lookup> {
			lookup call_function() { return this->front(); }
			std::span<lookup> call_arguments() { return std::span<lookup>{*this}.subspan(1); }

			static function_inputs to_lookup(const doir::function_inputs& inputs) {
				function_inputs out; out.reserve(inputs.related.size());
				for(auto& i: inputs.related)
					out.emplace_back(i);
				return out;
			}
		};
		struct block : public std::vector<lookup> {};
		struct alias : public lookup {};
		struct type_of : public lookup {};
		struct call : public lookup {};
	}

	// (inputs...) -> return_type
	ecrs::entity_t make_function_type(doir::module &mod, std::span<ecrs::entity_t> argument_types, std::optional<ecrs::entity_t> return_type = {});
	ecrs::entity_t make_function_type(doir::module &mod, std::span<lookup::lookup> argument_types, std::optional<lookup::lookup> return_type = {});

	struct function_builder;

	struct block_builder {
		ecrs::entity_t block = 0;
		doir::module* mod = nullptr;
		static block_builder create(doir::module& mod);

		ecrs::entity_t end(std::optional<diagnose::source_location> location = {});

		// "type_of" spec
		// %0 : i32 = 5
		ecrs::entity_t push_number(interned_string name, ecrs::entity_t type, long double value);
		ecrs::entity_t push_number(interned_string name, interned_string type_lookup, long double value);
		// %1 : u8p = "hello world"
		ecrs::entity_t push_string(interned_string name, ecrs::entity_t type, interned_string value);
		ecrs::entity_t push_string(interned_string name, interned_string type_lookup, interned_string value);
		// %2 : i32
		ecrs::entity_t push_valueless(interned_string name, ecrs::entity_t type);
		ecrs::entity_t push_valueless(interned_string name, interned_string type_lookup);
		// %4 : i32 = add(%0, %2)
		ecrs::entity_t push_call(interned_string name, ecrs::entity_t type, ecrs::entity_t function, std::span<ecrs::entity_t> arguments);
		ecrs::entity_t push_call(interned_string name, interned_string type_lookup, ecrs::entity_t function, std::span<ecrs::entity_t> arguments);
		ecrs::entity_t push_call(interned_string name, ecrs::entity_t type, interned_string function_lookup, std::span<lookup::lookup> arguments);
		ecrs::entity_t push_call(interned_string name, interned_string type_lookup, interned_string function_lookup, std::span<lookup::lookup> arguments);
		ecrs::entity_t push_call(interned_string name, ecrs::entity_t type, ecrs::entity_t function, std::span<lookup::lookup> arguments);
		ecrs::entity_t push_call(interned_string name, interned_string type_lookup, ecrs::entity_t function, std::span<lookup::lookup> arguments);

		// %5 : i32 = { built block... }
		block_builder push_subblock(interned_string name, ecrs::entity_t type);
		block_builder push_subblock(interned_string name, interned_string type_lookup);

		// "function" spec
		// add : (a: i32, b: i32 = 5) i32 = { built block... }
		function_builder push_function(interned_string name, ecrs::entity_t function_type);
		// foo : () void
		ecrs::entity_t push_valueless_function(interned_string name, ecrs::entity_t function_type);

		// "type" spec
		// vec3 : type = { x : f32; y : f32; z : f32; }
		block_builder push_type(interned_string name);

		// "alias" spec
		// color : alias = vec3
		ecrs::entity_t push_alias(interned_string name, ecrs::entity_t ref);

		// "block" spec
		// then : block = { built block... }
		block_builder push_quoted_block(interned_string name);

		// "namespace" spec
		// math : namespace = { built block... }
		block_builder push_namespace(interned_string name);
	};

	struct function_builder: public block_builder {
		// (a : i32 = 5)
		ecrs::entity_t push_number_parameter(size_t index, interned_string name, ecrs::entity_t type, long double value);
		ecrs::entity_t push_number_parameter(size_t index, interned_string name, interned_string type_lookup, long double value);
		// (b : u8p = "hello")
		ecrs::entity_t push_string_parameter(size_t index, interned_string name, ecrs::entity_t type, interned_string value);
		ecrs::entity_t push_string_parameter(size_t index, interned_string name, interned_string type_lookup, interned_string value);
		// (c : i32)
		ecrs::entity_t push_valueless_parameter(size_t index, interned_string name, ecrs::entity_t type);
		ecrs::entity_t push_valueless_parameter(size_t index, interned_string name, interned_string type_lookup);
	};

}
