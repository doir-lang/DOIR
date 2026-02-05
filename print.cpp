#include "print.hpp"
#include "interface.hpp"
#include "module.hpp"

std::string assignment_type(const doir::module& mod, ecrs::entity_t type, bool debug) {
	return "TODO: Implement";
}

std::ostream& print_location(std::ostream& out, const doir::module& mod, const doir::source_location& loc) {
	auto start = loc.start(mod.source);
	auto end = loc.end(mod.source);
	return out << '<' << loc.file << ":" << start.line << "-" << end.line << ":" << start.column << "-" << end.column << ">";
}

std::tuple<std::string, std::string, std::optional<doir::source_location>, std::string> get_common_assignment_elements(const doir::module& mod, ecrs::entity_t root, bool debug) {
	std::string ident = std::string(mod.get_component<doir::name>(root));
	if(debug) ident += "(" + std::to_string(root) + ")";

	std::string type = "<error>";
	if(mod.has_component<doir::type_of>(root))
		type = assignment_type(mod, mod.get_component<doir::type_of>(root).related[0], debug);
	else if(mod.has_component<doir::lookup::type_of>(root))
		type = debug ?
			"lookup(" + std::string(mod.get_component<doir::lookup::type_of>(root).name()) + ")"
			: std::string(mod.get_component<doir::lookup::type_of>(root).name());

	std::optional<doir::source_location> location = {};
	if(mod.has_component<doir::source_location>(root))
		location = mod.get_component<doir::source_location>(root);

	std::string Export = "";
	if(mod.has_component<doir::flags>(root))
		Export = mod.get_component<doir::flags>(root).export_set() ? "export " : "";

	return {ident, type, location, Export};
}

std::ostream& print_impl(std::ostream& out, const doir::module& mod, ecrs::entity_t root, bool pretty, bool debug, size_t indent = 0) {
	auto indent_string = std::string(indent, '\t');
	if(mod.has_component<doir::valueless>(root)) {
		auto [ident, type, location, Export] = get_common_assignment_elements(mod, root, debug);
		out << indent_string << Export << ident << (pretty ? ": " : ":") << type;
		if(location) print_location(out, mod, *location);

	} else if(mod.has_component<doir::number>(root)) {
		auto [ident, type, location, Export] = get_common_assignment_elements(mod, root, debug);
		auto value = mod.get_component<doir::number>(root).value;
		out << indent_string << Export << ident << (pretty ? ": " : ":") << type << (pretty ? " = " : "=") << value;
		if(location) print_location(out, mod, *location);

	} else if(mod.has_component<doir::string>(root)) {
		auto [ident, type, location, Export] = get_common_assignment_elements(mod, root, debug);
		auto value = mod.get_component<doir::string>(root).value;
		out << indent_string << Export << ident << (pretty ? ": " : ":") << type << (pretty ? " = " : "=") << value;
		if(location) print_location(out, mod, *location);

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
