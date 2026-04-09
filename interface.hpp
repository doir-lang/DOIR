#pragma once

#include "string_helpers.hpp"
#include "libecrs/relation.hpp"
#include <diagnose/diagnostics.hpp>
#include <unordered_set>
#include <variant>

namespace ecrs {
	using entity_t = uint32_t;
}

namespace doir {

	constexpr static ecrs::entity_t current_canonicalize_root = -2;

	struct module;
	namespace verify {
		#define DOIR_BUILTIN_NAMES {"type", "alias", "namespace"}

		bool entity_exists(diagnose::manager& diagnostics, module& module, ecrs::entity_t root);
		bool identifier_structure(diagnose::manager& diagnostics, module& module, interned_string ident, bool allow_builtins = true); // Builtins are things like type and alias
		bool structure(diagnose::manager& diagnostics, module& module, ecrs::entity_t root, bool top_level = true, ecrs::entity_t builtin_end = ecrs::invalid_entity);
	}

	void copy_components(module& mod, ecrs::entity_t out, ecrs::entity_t subtree, bool copy_block = true, std::unordered_map<ecrs::entity_t, ecrs::entity_t>* subtitutions = nullptr);
	ecrs::entity_t deep_copy(module& module, ecrs::entity_t root, void(*extra_copy_instructions)(ecrs::entity_t dest, ecrs::entity_t src) = nullptr);

	// Tags
	struct flags {
		enum impl : uint16_t {
			None = 0,
			Valueless = (1 << 1),
			Namespace = (1 << 2),

			Export = (1 << 3),
			Comptime = (1 << 4),
			Constant = (1 << 5),
			Union = (1 << 6),
			Pure = (1 << 7),
			Inline = (1 << 8),
			Flatten = (1 << 9),
			Tail = (1 << 10),
		} flags = None;

		inline uint16_t& as_underlying() { return (uint16_t&)flags; }
		inline bool valueless_set() const { return flags & Valueless; }
		inline bool namespace_set() const { return flags & Namespace; }

		inline bool export_set() const { return flags & Export; }
		inline bool comptime_set() const { return flags & Comptime; }
		inline bool constant_set() const { return flags & Constant; }
		inline bool union_set() const { return flags & Union; }
		inline bool pure_set() const { return flags & Pure; }
		inline bool inline_set() const { return flags & Inline; }
		inline bool flatten_set() const { return flags & Flatten; }
		inline bool tail_set() const { return flags & Tail; }
	};

	struct name : public interned_string {};

	struct block : public ecrs::relation<> {}; // When alone (no type_of etc...) represents a quoted block
	struct parent : public ecrs::relation<1> {};

	struct function_return_type : public ecrs::relation<1> {};  // Also expects function_inputs and block/valueless attached
	struct function_inputs : public ecrs::relation<> {
		std::vector<ecrs::entity_t> associated_parameters(const module& mod, const doir::block& block);
	}; // In a call the first input is the function to call
	struct function_parameter_names : std::vector<interned_string> {};
	struct function_parameter {
		size_t index; // Increments to indicate the order of the parameters
	};

	struct type_definition { // Also expects block attached
		size_t size, align, unique = 0;
	};

	struct pointer : public ecrs::relation<1> { size_t size = 0; }; // Size == 0 implies no bounds information

	struct alias : public ecrs::relation<1> {
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
	struct print_as_call : public call {}; // Attached to compile time substitutions to indicate what call created them

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

			static void swap_entities(lookup& self, const ecrs::context&, ecrs::entity_t a, ecrs::entity_t b) {
				if(!self.resolved()) return;
				if(self.entity() == a) self.entity() = b;
				else if(self.entity() == b) self.entity() = a;
			}
		};
		struct function_return_type : public lookup {};
		struct function_inputs : public std::vector<lookup> {
			static function_inputs to_lookup(const doir::function_inputs& inputs) {
				function_inputs out; out.reserve(inputs.related.size());
				for(auto& i: inputs.related)
					out.emplace_back(i);
				return out;
			}

			std::vector<ecrs::entity_t> associated_parameters(const module& mod, const doir::block& block);
			static void swap_entities(function_inputs& self, const ecrs::context& ctx, ecrs::entity_t a, ecrs::entity_t b) {
				for(auto& l: self) lookup::swap_entities(l, ctx, a, b);
			}
		};
		// struct block : public std::vector<lookup> {};
		struct alias : public lookup {
			std::optional<std::string_view> file = {}; // Aliases can reference other files
		};
		struct type_of : public lookup {};
		struct call : public lookup {};
	}

	struct function_builder;

	struct block_builder {
		ecrs::entity_t block = 0;
		doir::module* mod = nullptr;
		static block_builder create(doir::module& mod);

		ecrs::entity_t end();

		block_builder& build_global_block();
		static const std::unordered_set<ecrs::entity_t>& get_type_modifiers(const doir::module& mod, ecrs::entity_t root);
		block_builder& clear();
		// Both of these functions append to the existing block content...
		//	Thus it may need to be cleared first
		block_builder& move_exisiting(block_builder& source);
		block_builder& copy_existing(const block_builder& source, bool skip_parameters = false);

		// "type_of" spec
		// %0 : i32 = 5
		static ecrs::entity_t attach_number(doir::module& mod, ecrs::entity_t to, ecrs::entity_t type, long double value);
		ecrs::entity_t push_number(interned_string name, ecrs::entity_t type, long double value);
		static ecrs::entity_t attach_number(doir::module& mod, ecrs::entity_t to, interned_string type_lookup, long double value);
		ecrs::entity_t push_number(interned_string name, interned_string type_lookup, long double value);
		// %1 : u8p = "hello world"
		static ecrs::entity_t attach_string(doir::module& mod, ecrs::entity_t to, ecrs::entity_t type, interned_string value);
		ecrs::entity_t push_string(interned_string name, ecrs::entity_t type, interned_string value);
		static ecrs::entity_t attach_string(doir::module& mod, ecrs::entity_t to, interned_string type_lookup, interned_string value);
		ecrs::entity_t push_string(interned_string name, interned_string type_lookup, interned_string value);
		// %2 : i32
		static ecrs::entity_t attach_valueless(doir::module& mod, ecrs::entity_t to, ecrs::entity_t type);
		ecrs::entity_t push_valueless(interned_string name, ecrs::entity_t type);
		static ecrs::entity_t attach_valueless(doir::module& mod, ecrs::entity_t to, interned_string type_lookup);
		ecrs::entity_t push_valueless(interned_string name, interned_string type_lookup);
		// %4 : i32 = add(%0, %2)
		static ecrs::entity_t attach_call(doir::module& mod, ecrs::entity_t to, ecrs::entity_t type, ecrs::entity_t function, std::span<ecrs::entity_t> arguments);
		ecrs::entity_t push_call(interned_string name, ecrs::entity_t type, ecrs::entity_t function, std::span<ecrs::entity_t> arguments);
		static ecrs::entity_t attach_call(doir::module& mod, ecrs::entity_t to, interned_string type_lookup, ecrs::entity_t function, std::span<ecrs::entity_t> arguments);
		ecrs::entity_t push_call(interned_string name, interned_string type_lookup, ecrs::entity_t function, std::span<ecrs::entity_t> arguments);
		static ecrs::entity_t attach_call(doir::module& mod, ecrs::entity_t to, ecrs::entity_t type, interned_string function_lookup, std::span<lookup::lookup> arguments);
		ecrs::entity_t push_call(interned_string name, ecrs::entity_t type, interned_string function_lookup, std::span<lookup::lookup> arguments);
		static ecrs::entity_t attach_call(doir::module& mod, ecrs::entity_t to, interned_string type_lookup, interned_string function_lookup, std::span<lookup::lookup> arguments);
		ecrs::entity_t push_call(interned_string name, interned_string type_lookup, interned_string function_lookup, std::span<lookup::lookup> arguments);
		static ecrs::entity_t attach_call(doir::module& mod, ecrs::entity_t to, ecrs::entity_t type, ecrs::entity_t function, std::span<lookup::lookup> arguments);
		ecrs::entity_t push_call(interned_string name, ecrs::entity_t type, ecrs::entity_t function, std::span<lookup::lookup> arguments);
		static ecrs::entity_t attach_call(doir::module& mod, ecrs::entity_t to, interned_string type_lookup, ecrs::entity_t function, std::span<lookup::lookup> arguments);
		ecrs::entity_t push_call(interned_string name, interned_string type_lookup, ecrs::entity_t function, std::span<lookup::lookup> arguments);

		// %5 : i32 = { built block... }
		static block_builder attach_subblock(doir::module& mod, ecrs::entity_t to, ecrs::entity_t type);
		block_builder push_subblock(interned_string name, ecrs::entity_t type);
		static block_builder attach_subblock(doir::module& mod, ecrs::entity_t to, interned_string type_lookup);
		block_builder push_subblock(interned_string name, interned_string type_lookup);

		// "function" spec
		// add : (a: i32, b: i32 = 5) i32 = { built block... }
		static function_builder attach_function(doir::module& mod, ecrs::entity_t to, ecrs::entity_t function_type, bool push_parameters = false);
		function_builder push_function(interned_string name, ecrs::entity_t function_type, bool push_parameters = false);
		// foo : () void
		static ecrs::entity_t attach_valueless_function(doir::module& mod, ecrs::entity_t to, ecrs::entity_t function_type);
		ecrs::entity_t push_valueless_function(interned_string name, ecrs::entity_t function_type);

		// "type" spec
		// vec3 : type = { x : f32; y : f32; z : f32; }
		static block_builder attach_type(doir::module& mod, ecrs::entity_t to);
		block_builder push_type(interned_string name);
		// func_t : type = (a: i32) -> f32
		static ecrs::entity_t attach_function_type(doir::module& mod, ecrs::entity_t to, std::span<ecrs::entity_t> parameter_types, std::optional<ecrs::entity_t> return_type = {}, std::span<interned_string> parameter_names = {});
		ecrs::entity_t push_function_type(interned_string name, std::span<ecrs::entity_t> parameter_types, std::optional<ecrs::entity_t> return_type = {}, std::span<interned_string> parameter_names = {});
		static ecrs::entity_t attach_function_type(doir::module& mod, ecrs::entity_t to, std::span<lookup::lookup> parameter_types, std::optional<lookup::lookup> return_type = {}, std::span<interned_string> parameter_names = {});
		ecrs::entity_t push_function_type(interned_string name, std::span<lookup::lookup> parameter_types, std::optional<lookup::lookup> return_type = {}, std::span<interned_string> parameter_names = {});
		// bp : type = type.pointer(byte)
		static ecrs::entity_t attach_pointer(doir::module& mod, ecrs::entity_t to, ecrs::entity_t base, size_t size = 0);
		ecrs::entity_t push_pointer(interned_string name, ecrs::entity_t base, size_t size = 0);

		// "alias" spec
		// color : alias = vec3
		static ecrs::entity_t attach_alias(doir::module& mod, ecrs::entity_t to, ecrs::entity_t ref);
		ecrs::entity_t push_alias(interned_string name, ecrs::entity_t ref);
		static ecrs::entity_t attach_alias(doir::module& mod, ecrs::entity_t to, interned_string ref_lookup);
		ecrs::entity_t push_alias(interned_string name, interned_string ref_lookup);

		// "block" spec
		// then : block = { built block... }
		// static block_builder attach_quoted_block(ecrs::entity_t to);
		// block_builder push_quoted_block(interned_string name);

		// "namespace" spec
		// math : namespace = { built block... }
		static block_builder attach_namespace(doir::module& mod, ecrs::entity_t to);
		block_builder push_namespace(interned_string name);
	};

	struct function_builder: public block_builder {
		void push_parameters(ecrs::entity_t function_type, std::span<interned_string> parameter_names = {});

		// (a : i32 = 5)
		static ecrs::entity_t attach_number_parameter(doir::module& mod, ecrs::entity_t to, size_t index, ecrs::entity_t type, long double value);
		ecrs::entity_t push_number_parameter(size_t index, interned_string name, ecrs::entity_t type, long double value, bool append = true);
		static ecrs::entity_t attach_number_parameter(doir::module& mod, ecrs::entity_t to, size_t index, interned_string type_lookup, long double value);
		ecrs::entity_t push_number_parameter(size_t index, interned_string name, interned_string type_lookup, long double value, bool append = true);
		// (b : u8p = "hello")
		static ecrs::entity_t attach_string_parameter(doir::module& mod, ecrs::entity_t to, size_t index, ecrs::entity_t type, interned_string value);
		ecrs::entity_t push_string_parameter(size_t index, interned_string name, ecrs::entity_t type, interned_string value, bool append = true);
		static ecrs::entity_t attach_string_parameter(doir::module& mod, ecrs::entity_t to, size_t index, interned_string type_lookup, interned_string value);
		ecrs::entity_t push_string_parameter(size_t index, interned_string name, interned_string type_lookup, interned_string value, bool append = true);
		// (c : i32)
		static ecrs::entity_t attach_valueless_parameter(doir::module& mod, ecrs::entity_t to, size_t index, ecrs::entity_t type);
		ecrs::entity_t push_valueless_parameter(size_t index, interned_string name, ecrs::entity_t type, bool append = true);
		static ecrs::entity_t attach_valueless_parameter(doir::module& mod, ecrs::entity_t to, size_t index, interned_string type_lookup);
		ecrs::entity_t push_valueless_parameter(size_t index, interned_string name, interned_string type_lookup, bool append = true);
	};

}
