#include <cassert>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>
#include <string_view>
#include <variant>
#include <vector>

using entity_t = size_t;

struct RelationBase {}; // Used for constraints

// Base
template<size_t N = std::dynamic_extent, bool CAN_BE_TERM = false>
struct Relation : public RelationBase {
	constexpr static bool can_be_term = CAN_BE_TERM;
	std::array<entity_t, N> related;

	constexpr Relation() {}
	constexpr Relation(std::array<entity_t, N> a): related(a) {}
	constexpr Relation(std::initializer_list<entity_t> initializer) {
		assert(initializer.size() <= N);
		auto init = initializer.begin();
		for(size_t i = 0; i < initializer.size(); ++i, ++init)
			related[i] = *init;
	}
	Relation(Relation&&) = default;
	Relation(const Relation&) = default;
	Relation& operator=(Relation&&) = default;
	Relation& operator=(const Relation&) = default;
};
template<bool CAN_BE_TERM>

struct Relation<std::dynamic_extent, CAN_BE_TERM> : public RelationBase {
	constexpr static bool can_be_term = CAN_BE_TERM;
	std::vector<entity_t> related;

	Relation() {}
	Relation(std::vector<entity_t> a): related(a) {}
	Relation(std::initializer_list<entity_t> e) : related(e) {}
	Relation(Relation&&) = default;
	Relation(const Relation&) = default;
	Relation& operator=(Relation&&) = default;
	Relation& operator=(const Relation&) = default;
};


// Tags
struct flags {
    enum impl : uint8_t {
        Public = (1 << 1),
        Comptime = (1 << 2), // On a function implies that the function can access the emitter object
        Constant = (1 << 3),
        Pure = (1 << 4),
		Inline = (1 << 5),
		Tail = (1 << 6),
    } flags;

    inline bool is_public() const { return flags & Public; }
    inline bool is_comptime() const { return flags & Comptime; }
    inline bool is_constant() const { return flags & Constant; }
    inline bool is_pure() const { return flags & Pure; }
};
struct public_ {};
struct comptime {}; // On a function implies that the function can access the emitter object
struct valueless {}; // Represents undefined values and external functions/aliases
struct namespace_ {}; // On a type element indicates that the namespace should be inherited

struct pointer { size_t size = 0; }; // Size == 0 implies no bounds information

struct name : public std::string_view {};

struct function_return_type : public Relation<1> {};  // Also expects function_inputs and block/valueless attached
struct function_inputs : public Relation<> {};

struct block : public Relation<> {}; // When alone (no type_of etc...) represents a quoted block

struct type_definition { // Also expects block attached
	size_t size, align;
};

struct alias : public Relation<1> {}; // Can be INVALID if a valueless is attached

struct type_of : public Relation<1> {}; // Expects a number, string, valueless, or block attached

struct number {
	long double value; // TODO: should use bigint rational instead?
};

struct string {
	std::string_view value;
};

struct call : public Relation<1> {}; // Also expects function_inputs attached

struct source_location {
	struct pair {
		size_t line, column;
	};

	std::string_view file;
	pair start, end;
};

namespace lookup {
	struct lookup : public std::variant<entity_t, std::string_view> {
		bool resolved() { return std::holds_alternative<entity_t>(*this); }
		entity_t& entity() { return std::get<entity_t>(*this); }
		std::string_view& name() { return std::get<std::string_view>(*this); }
	};
	struct function_return_type : public lookup {};
	struct function_inputs : public std::vector<lookup> {};
	struct block : public std::vector<lookup> {};
	struct alias : public lookup {};
	struct type_of : public lookup {};
	struct call : public lookup {};
}

struct function_builder;

struct block_builder {
	entity_t end(std::optional<source_location> location = {});

	// "type_of" spec
	// %0 : i32 = 5
	entity_t number(std::string_view name, entity_t type, long double value, std::optional<source_location> location = {});
	// %1 : u8p = "hello world"
	entity_t string(std::string_view name, entity_t type, std::string_view value, std::optional<source_location> location = {});
	// %2 : i32
	entity_t valueless(std::string_view name, entity_t type, std::optional<source_location> location = {});
	// %4 : i32 = add(%0, %2)
	entity_t call(std::string_view name, entity_t type, entity_t function, std::span<entity_t> arguments, std::optional<source_location> location = {});
	// %5 : i32 = { built block... }
	block_builder subblock(std::string_view name, entity_t type, std::optional<source_location> location = {});

	// "function" spec
	// add : (a: i32, b: i32 = 5) i32 = { built block... }
	function_builder function(std::string_view name, entity_t return_type, std::optional<source_location> location = {});
	// foo : () void = extern
	function_builder extern_function(std::string_view name, entity_t return_type, std::optional<source_location> location = {});

	// "type" spec
	// vec3 : type = { x : f32; y : f32; z : f32; }
	block_builder type(std::string_view name, std::optional<source_location> location = {});

	// "alias" spec
	// color : alias = vec3
	entity_t alias(std::string_view name, entity_t ref, std::optional<source_location> location = {});

	// "block" spec
	// then : block = { built block... }
	block_builder quoted_block(std::string_view name, std::optional<source_location> location = {});
};

struct function_builder: public block_builder {
	// (a : i32 = 5)
	entity_t number_paremeter(std::string_view name, entity_t type, long double value, std::optional<source_location> location = {});
	// (b : u8p = "hello")
	entity_t string_parameter(std::string_view name, entity_t type, std::string_view value, std::optional<source_location> location = {});
	// (c : i32)
	entity_t valueless_parameter(std::string_view name, entity_t type, std::optional<source_location> location = {});
};
