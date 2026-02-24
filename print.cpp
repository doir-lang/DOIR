#include "diagnostics.hpp"
#include <string>
#define NOMINMAX
#define WIN32_LEAN_AND_MEAN

#include "module.hpp"
#include "print.hpp"
#include "interface.hpp"

#include <sstream>

std::ostream& print_impl(std::ostream& out, const doir::module& mod, ecrs::entity_t subtree, bool pretty, bool debug, size_t indent = 0);

std::string print_lookup_name(const doir::module& mod, doir::lookup::lookup lookup, bool debug) {
	if(!lookup.resolved())
		return debug ? "lookup(" + std::string(lookup.name()) + ")" : std::string(lookup.name());

	if(mod.has_component<doir::name>(lookup.entity())) {
		auto out = std::string(mod.get_component<doir::name>(lookup.entity()));
		if(debug) out += "[" + std::to_string(lookup.entity()) + "]";
		return out;
	}

	if(mod.has_component<doir::function_inputs>(lookup.entity()) || mod.has_component<doir::lookup::function_inputs>(lookup.entity())) {
		auto inputs = mod.has_component<doir::function_inputs>(lookup.entity())
			? doir::lookup::function_inputs::to_lookup(mod.get_component<doir::function_inputs>(lookup.entity()))
			: mod.get_component<doir::lookup::function_inputs>(lookup.entity());
		std::optional<doir::lookup::function_return_type> return_type = {};
		if(mod.has_component<doir::function_return_type>(lookup.entity()))
			return_type = {mod.get_component<doir::function_return_type>(lookup.entity()).related[0]};
		else if(mod.has_component<doir::function_return_type>(lookup.entity()))
			return_type = mod.get_component<doir::lookup::function_return_type>(lookup.entity());

		std::ostringstream out;
		out << "(";
		for(size_t i = 0; i < inputs.size(); ++i)
			out << (i > 0 ? "," : "") << "%" << i << ":" << print_lookup_name(mod, inputs[i], debug);
		out << ")";

		if(return_type)
			out << "->" << print_lookup_name(mod, *return_type, debug);
		if(debug)
			out << "[" << lookup.entity() << "]";
		return out.str();
	}

	return "%" + std::to_string(lookup.entity());
}


std::tuple<std::string, std::string, std::optional<diagnose::source_location::detailed>, std::string> get_common_assignment_elements(const doir::module& mod, ecrs::entity_t subtree, bool debug) {
	std::string ident;
	if(mod.has_component<doir::name>(subtree)) {
		ident = std::string(mod.get_component<doir::name>(subtree));
		if(debug) ident += "[" + std::to_string(subtree) + "]";
	} else ident = "%" + std::to_string(subtree);

	std::string type = "<error>";
	if(mod.has_component<doir::type_of>(subtree))
		type = print_lookup_name(mod, mod.get_component<doir::type_of>(subtree).related[0], debug);
	else if(mod.has_component<doir::lookup::type_of>(subtree))
		type = print_lookup_name(mod, mod.get_component<doir::lookup::type_of>(subtree), debug);
	else if(mod.has_component<doir::type_definition>(subtree))
		type = "type";
	else if(mod.has_component<doir::flags>(subtree) && mod.get_component<doir::flags>(subtree).namespace_set())
		type = "namespace";

	std::optional<diagnose::source_location::detailed> location = {};
	if(mod.has_component<diagnose::source_location::detailed>(subtree))
		location = mod.get_component<diagnose::source_location::detailed>(subtree);
	else if(mod.has_component<diagnose::source_location>(subtree))
		location = mod.get_component<diagnose::source_location>(subtree).to_detailed(mod.source);

	std::string Export = "";
	if(mod.has_component<doir::flags>(subtree))
		Export = mod.get_component<doir::flags>(subtree).export_set() ? "export " : "";

	return {ident, type, location, Export};
}

std::ostream& print_block(std::ostream& out, const doir::module& mod, const doir::block& block, bool pretty, bool debug, bool skip_parameters, size_t indent) {
	out << "{" << (pretty ? "\n" : "");
	for(auto& elem: block.related) {
		if(skip_parameters && mod.has_component<doir::function_parameter>(elem))
			continue;
		print_impl(out, mod, elem, pretty, debug, indent + 1);
		if(pretty) out << std::endl;
		else out << ";";
	}
	out << (pretty ? std::string(indent, '\t') : "") << "}";
	return out;
}

std::ostream& print_type_of(std::ostream& out, const doir::module& mod, ecrs::entity_t subtree, bool pretty, bool debug, size_t indent) {
	auto indent_string = pretty ? std::string(indent, '\t') : "";
	if(mod.has_component<doir::flags>(subtree) && mod.get_component<doir::flags>(subtree).valueless_set()) {
		auto [ident, type, location, Export] = get_common_assignment_elements(mod, subtree, debug);
		out << indent_string << Export << ident << (pretty ? ": " : ":") << type;
		if(location) out << *location;

	} else if(mod.has_component<doir::number>(subtree)) {
		auto [ident, type, location, Export] = get_common_assignment_elements(mod, subtree, debug);
		auto value = mod.get_component<doir::number>(subtree).value;
		out << indent_string << Export << ident << (pretty ? ": " : ":") << type << (pretty ? " = " : "=") << value;
		if(location) out << *location;

	} else if(mod.has_component<doir::string>(subtree)) {
		auto [ident, type, location, Export] = get_common_assignment_elements(mod, subtree, debug);
		auto value = mod.get_component<doir::string>(subtree).value;
		out << indent_string << Export << ident << (pretty ? ": " : ":") << type << (pretty ? " = " : "=") << value;
		if(location) out << *location;

	} else if(mod.has_component<doir::call>(subtree) || mod.has_component<doir::lookup::call>(subtree)) {
		auto [ident, type, location, Export] = get_common_assignment_elements(mod, subtree, debug);
		doir::lookup::lookup call = mod.has_component<doir::call>(subtree)
			? doir::lookup::lookup(mod.get_component<doir::call>(subtree).related[0])
			: doir::lookup::lookup(mod.get_component<doir::lookup::call>(subtree));
		auto inputs = mod.has_component<doir::function_inputs>(subtree)
			? doir::lookup::function_inputs::to_lookup(mod.get_component<doir::function_inputs>(subtree))
			: mod.get_component<doir::lookup::function_inputs>(subtree);
		std::string flags = "";
		if(mod.has_component<doir::flags>(subtree)) {
			auto f = mod.get_component<doir::flags>(subtree);
			if(f.inline_set()) flags += "inline ";
			if(f.flatten_set()) flags += "flatten ";
			if(f.tail_set()) flags += "tail ";
		}
		out << indent_string << Export << ident << (pretty ? ": " : ":") << type << (pretty ? " = " : "=")
			<< flags << print_lookup_name(mod, call, debug) << "(";

		for(size_t i = 0, size = inputs.size(); i < size; ++i) {
			if(i > 0) out << (pretty ? ", " : ",");
			out << print_lookup_name(mod, inputs[i], debug);
		}
		out << ")";

	} else if(mod.has_component<doir::function_return_type>(subtree) || mod.has_component<doir::lookup::function_return_type>(subtree)) {
		auto [ident, type, location, Export] = get_common_assignment_elements(mod, subtree, debug);
		out << indent_string << Export << ident << (pretty ? ": " : ":");

		auto ft = mod.get_component<doir::type_of>(subtree).related[0];
		auto inputs = mod.has_component<doir::function_inputs>(ft)
			? doir::lookup::function_inputs::to_lookup(mod.get_component<doir::function_inputs>(ft))
			: mod.get_component<doir::lookup::function_inputs>(ft);
		std::optional<doir::lookup::function_return_type> return_type = {};
		if(mod.has_component<doir::function_return_type>(ft))
			return_type = {mod.get_component<doir::function_return_type>(ft).related[0]};
		else if(mod.has_component<doir::lookup::function_return_type>(ft))
			return_type = mod.get_component<doir::lookup::function_return_type>(ft);

		if(mod.has_component<doir::block>(subtree)) {
			auto parameters = inputs.associated_parameters(mod, mod.get_component<doir::block>(subtree));

			out << "(";
			for(size_t i = 0; i < parameters.size(); ++i)
				print_impl(out, mod, parameters[i], pretty, debug) << (i < parameters.size() - 1 ? (pretty ? ", " : ",") : "");
			out << ")";

			if(return_type)
				out << (pretty ? " -> " : "->") << print_lookup_name(mod, *return_type, debug);
			if(debug)
				out << "[" << ft << "]";

			out << (pretty ? " = " : "=");
			print_block(out, mod, mod.get_component<doir::block>(subtree), pretty, debug, true, indent);
		} else { // Valueless function
			out << "(";
			for(size_t i = 0; i < inputs.size(); ++i)
				out << (i > 0 ? (pretty ? ", " : ", ") : "") << "%" << i << (pretty ? ": " : ":") << print_lookup_name(mod, inputs[i], debug);
			out << ")";

			if(return_type)
				out << (pretty ? " -> " : "->") << print_lookup_name(mod, *return_type, debug);
			if(debug)
				out << "[" << ft << "]";
		}

	} else if(mod.has_component<doir::block>(subtree)) {
		auto [ident, type, location, Export] = get_common_assignment_elements(mod, subtree, debug);
		out << indent_string << Export << ident << (pretty ? ": " : ":") << type << (pretty ? " = " : "=");
		print_block(out, mod, mod.get_component<doir::block>(subtree), pretty, debug, false, indent);

	} else out << "<type_of error>";
	return out;
}

std::ostream& print_impl(std::ostream& out, const doir::module& mod, ecrs::entity_t subtree, bool pretty, bool debug, size_t indent /*= 0*/) {
	auto indent_string = pretty ? std::string(indent, '\t') : "";

	if(mod.has_component<doir::type_of>(subtree) || mod.has_component<doir::lookup::type_of>(subtree))
		print_type_of(out, mod, subtree, pretty, debug, indent);
	else if(mod.has_component<doir::type_definition>(subtree)) {
		auto [ident, type, location, Export] = get_common_assignment_elements(mod, subtree, debug);
		out << indent_string << Export << ident << (pretty ? ": " : ":") << type << (pretty ? " = " : "=");
		print_block(out, mod, mod.get_component<doir::block>(subtree), pretty, debug, false, indent);

	} else if(mod.has_component<doir::flags>(subtree) && mod.get_component<doir::flags>(subtree).namespace_set()) {
		auto [ident, type, location, Export] = get_common_assignment_elements(mod, subtree, debug);
		out << indent_string << Export << ident << (pretty ? ": " : ":") << type << (pretty ? " = " : "=");
		print_block(out, mod, mod.get_component<doir::block>(subtree), pretty, debug, false, indent);

	} else if(mod.has_component<doir::alias>(subtree) || mod.has_component<doir::lookup::alias>(subtree)) {
		auto [ident, type, location, Export] = get_common_assignment_elements(mod, subtree, debug);
		auto alias = mod.has_component<doir::alias>(subtree)
			? doir::lookup::alias(mod.get_component<doir::alias>(subtree).related[0], mod.get_component<doir::alias>(subtree).file)
			: mod.get_component<doir::lookup::alias>(subtree);

		out << indent_string << Export << ident << (pretty ? ": " : ":") << type << (pretty ? " = " : "=")
			<< print_lookup_name(mod, alias, debug);
		if(debug && alias.file)
			out << "[" << *alias.file << "]";

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
