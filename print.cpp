#define NOMINMAX
#define WIN32_LEAN_AND_MEAN

#include "module.hpp"
#include "print.hpp"
#include "interface.hpp"

std::ostream& print_impl(std::ostream& out, const doir::module& mod, ecrs::entity_t root, bool pretty, bool debug, size_t indent = 0);

std::string assignment_type(const doir::module& mod, ecrs::entity_t type, bool debug) {
	return "TODO: Implement";
}

std::string print_lookup_name(const doir::module& mod, doir::lookup::lookup lookup, bool debug) {
	if(!lookup.resolved())
		return debug ? "lookup(" + std::string(lookup.name()) + ")" : std::string(lookup.name());

	if(mod.has_component<doir::name>(lookup.entity()))
		return std::string(mod.get_component<doir::name>(lookup.entity()));

	return "%" + std::to_string(lookup.entity());
}


std::tuple<std::string, std::string, std::optional<diagnose::source_location::detailed>, std::string> get_common_assignment_elements(const doir::module& mod, ecrs::entity_t root, bool debug) {
	std::string ident;
	if(mod.has_component<doir::name>(root)) {
		ident = std::string(mod.get_component<doir::name>(root));
		if(debug) ident += "(" + std::to_string(root) + ")";
	} else ident = "%" + std::to_string(root);

	std::string type = "<error>";
	if(mod.has_component<doir::type_of>(root))
		type = assignment_type(mod, mod.get_component<doir::type_of>(root).related[0], debug);
	else if(mod.has_component<doir::lookup::type_of>(root))
		type = print_lookup_name(mod, mod.get_component<doir::lookup::type_of>(root), debug);
	else if(mod.has_component<doir::type_definition>(root))
		type = "type";
	else if(mod.has_component<doir::Namespace>(root))
		type = "namespace";

	std::optional<diagnose::source_location::detailed> location = {};
	if(mod.has_component<diagnose::source_location::detailed>(root))
		location = mod.get_component<diagnose::source_location::detailed>(root);
	else if(mod.has_component<diagnose::source_location>(root))
		location = mod.get_component<diagnose::source_location>(root).to_detailed(mod.source);

	std::string Export = "";
	if(mod.has_component<doir::flags>(root))
		Export = mod.get_component<doir::flags>(root).export_set() ? "export " : "";

	return {ident, type, location, Export};
}

std::ostream& print_block(std::ostream& out, const doir::module& mod, const doir::block& block, bool pretty, bool debug, size_t indent) {
	out << "{" << (pretty ? "\n" : "");
	for(auto& elem: block.related) {
		print_impl(out, mod, elem, pretty, debug, indent + 1);
		if(pretty) out << std::endl;
		else out << ";";
	}
	out << (pretty ? std::string(indent, '\t') : "") << "}";
	return out;
}

std::ostream& print_type_of(std::ostream& out, const doir::module& mod, ecrs::entity_t root, bool pretty, bool debug, size_t indent) {
	auto indent_string = pretty ? std::string(indent, '\t') : "";
	if(mod.has_component<doir::valueless>(root)) {
		auto [ident, type, location, Export] = get_common_assignment_elements(mod, root, debug);
		out << indent_string << Export << ident << (pretty ? ": " : ":") << type;
		if(location) out << *location;

	} else if(mod.has_component<doir::number>(root)) {
		auto [ident, type, location, Export] = get_common_assignment_elements(mod, root, debug);
		auto value = mod.get_component<doir::number>(root).value;
		out << indent_string << Export << ident << (pretty ? ": " : ":") << type << (pretty ? " = " : "=") << value;
		if(location) out << *location;

	} else if(mod.has_component<doir::string>(root)) {
		auto [ident, type, location, Export] = get_common_assignment_elements(mod, root, debug);
		auto value = mod.get_component<doir::string>(root).value;
		out << indent_string << Export << ident << (pretty ? ": " : ":") << type << (pretty ? " = " : "=") << value;
		if(location) out << *location;

	} else if(mod.has_component<doir::function_inputs>(root)) {
		auto [ident, type, location, Export] = get_common_assignment_elements(mod, root, debug);
		auto call = mod.get_component<doir::function_inputs>(root);
		auto args = call.call_arguments();
		std::string flags = "";
		if(mod.has_component<doir::flags>(root)) {
			auto f = mod.get_component<doir::flags>(root);
			if(f.inline_set()) flags += "inline ";
			if(f.flatten_set()) flags += "flatten ";
			if(f.tail_set()) flags += "tail ";
		}
		out << indent_string << Export << ident << (pretty ? ": " : ":") << type << (pretty ? " = " : "=")
			<< flags << print_lookup_name(mod, call.call_function(), debug) << "(";

		for(size_t i = 0, size = args.size(); i < size; ++i) {
			if(i > 0) out << (pretty ? ", " : ",");
			out << print_lookup_name(mod, args[i], debug);
		}
		out << ")";

	} else if(mod.has_component<doir::lookup::function_inputs>(root)) {
		auto [ident, type, location, Export] = get_common_assignment_elements(mod, root, debug);
		auto call = mod.get_component<doir::lookup::function_inputs>(root);
		auto args = call.call_arguments();
		std::string flags = "";
		if(mod.has_component<doir::flags>(root)) {
			auto f = mod.get_component<doir::flags>(root);
			if(f.inline_set()) flags += "inline ";
			if(f.flatten_set()) flags += "flatten ";
			if(f.tail_set()) flags += "tail ";
		}
		out << indent_string << Export << ident << (pretty ? ": " : ":") << type << (pretty ? " = " : "=")
			<< flags << print_lookup_name(mod, call.call_function(), debug) << "(";

		for(size_t i = 0, size = args.size(); i < size; ++i) {
			if(i > 0) out << (pretty ? ", " : ",");
			out << print_lookup_name(mod, args[i], debug);
		}
		out << ")";

	} else if(mod.has_component<doir::block>(root)) {
		auto [ident, type, location, Export] = get_common_assignment_elements(mod, root, debug);
		out << indent_string << Export << ident << (pretty ? ": " : ":") << type << (pretty ? " = " : "=");
		print_block(out, mod, mod.get_component<doir::block>(root), pretty, debug, indent);

	} else out << "<type_of error>";
	return out;
}

std::ostream& print_impl(std::ostream& out, const doir::module& mod, ecrs::entity_t root, bool pretty, bool debug, size_t indent /*= 0*/) {
	auto indent_string = pretty ? std::string(indent, '\t') : "";

	if(mod.has_component<doir::type_of>(root) || mod.has_component<doir::lookup::type_of>(root))
		print_type_of(out, mod, root, pretty, debug, indent);
	else if(mod.has_component<doir::type_definition>(root)) {
		auto [ident, type, location, Export] = get_common_assignment_elements(mod, root, debug);
		out << indent_string << Export << ident << (pretty ? ": " : ":") << type << (pretty ? " = " : "=");
		print_block(out, mod, mod.get_component<doir::block>(root), pretty, debug, indent);

	} else if(mod.has_component<doir::Namespace>(root)) {
		auto [ident, type, location, Export] = get_common_assignment_elements(mod, root, debug);
		out << indent_string << Export << ident << (pretty ? ": " : ":") << type << (pretty ? " = " : "=");
		print_block(out, mod, mod.get_component<doir::block>(root), pretty, debug, indent);

	} else out << "<error>";
	return out;
}

std::ostream& doir::print(std::ostream& out, const doir::module& mod, ecrs::entity_t root, bool pretty /* = true */, bool debug /*= false */) {
	// If the root is a block, print the contents of the block
	if(mod.has_component<doir::block>(root))
		for(auto& elem: mod.get_component<doir::block>(root).related) {
			print_impl(out, mod, elem, pretty, debug);
			if(pretty) out << std::endl;
			else out << ";";
		}
	else print_impl(out, mod, root, pretty, debug);
	return out;
}
