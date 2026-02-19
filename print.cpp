#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#define FP_OSTREAM_SUPPORT

#include "module.hpp"
#include "print.hpp"
#include "interface.hpp"

#include <sstream>

std::ostream& print_impl(std::ostream& out, const doir::module& mod, ecrs::entity_t root, bool pretty, bool debug, size_t indent = 0);

fp::raii::string print_lookup_name(const doir::module& mod, doir::lookup::lookup lookup, bool debug) {
	if(!lookup.resolved())
		return debug ? "lookup("_fpv + lookup.name().make_dynamic().auto_free() + ")"_fpv : lookup.name().make_dynamic();

	if(mod.has_component<doir::name>(lookup.entity())) {
		auto out = mod.get_component<doir::name>(lookup.entity()).make_dynamic().auto_free();
		if(debug) out += ("[" + fp::raii::string::format("{}", lookup.entity()) + "]").full_view();
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
		return fp::string::view(std::string_view{out.str()}).make_dynamic().auto_free();
	}

	return "%" + fp::raii::string::format("{}", lookup.entity());
}


std::tuple<fp::raii::string, fp::raii::string, std::optional<diagnose::source_location::detailed>, fp::raii::string> get_common_assignment_elements(const doir::module& mod, ecrs::entity_t root, bool debug) {
	fp::raii::string ident;
	if(mod.has_component<doir::name>(root)) {
		ident = mod.get_component<doir::name>(root).make_dynamic();
		if(debug) ident += ("[" + fp::raii::string::format("{}", root) + "]").full_view();
	} else ident = "%" + fp::raii::string::format("{}", root);

	fp::raii::string type = "<error>";
	if(mod.has_component<doir::type_of>(root))
		type = print_lookup_name(mod, mod.get_component<doir::type_of>(root).related[0], debug);
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
		location = mod.get_component<diagnose::source_location>(root).to_detailed(mod.source.to_std());

	fp::raii::string Export = "";
	if(mod.has_component<doir::flags>(root))
		Export = mod.get_component<doir::flags>(root).export_set() ? "export " : "";

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
	out << (pretty ? "\t"_fpr.replicate(indent).auto_free() : ""_fpr) << "}";
	return out;
}

std::ostream& print_type_of(std::ostream& out, const doir::module& mod, ecrs::entity_t root, bool pretty, bool debug, size_t indent) {
	auto indent_string = pretty ? "\t"_fpr.replicate(indent).auto_free() : ""_fpr;
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

	} else if(mod.has_component<doir::call>(root) || mod.has_component<doir::lookup::call>(root)) {
		auto [ident, type, location, Export] = get_common_assignment_elements(mod, root, debug);
		doir::lookup::lookup call = mod.has_component<doir::call>(root)
			? doir::lookup::lookup(mod.get_component<doir::call>(root).related[0])
			: doir::lookup::lookup(mod.get_component<doir::lookup::call>(root));
		auto inputs = mod.has_component<doir::function_inputs>(root)
			? doir::lookup::function_inputs::to_lookup(mod.get_component<doir::function_inputs>(root))
			: mod.get_component<doir::lookup::function_inputs>(root);
		fp::raii::string flags = "";
		if(mod.has_component<doir::flags>(root)) {
			auto f = mod.get_component<doir::flags>(root);
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

	} else if(mod.has_component<doir::function_return_type>(root) || mod.has_component<doir::lookup::function_return_type>(root)) {
		auto [ident, type, location, Export] = get_common_assignment_elements(mod, root, debug);
		out << indent_string << Export << ident << (pretty ? ": " : ":");

		auto ft = mod.get_component<doir::type_of>(root).related[0];
		auto inputs = mod.has_component<doir::function_inputs>(ft)
			? doir::lookup::function_inputs::to_lookup(mod.get_component<doir::function_inputs>(ft))
			: mod.get_component<doir::lookup::function_inputs>(ft);
		std::optional<doir::lookup::function_return_type> return_type = {};
		if(mod.has_component<doir::function_return_type>(ft))
			return_type = {mod.get_component<doir::function_return_type>(ft).related[0]};
		else if(mod.has_component<doir::lookup::function_return_type>(ft))
			return_type = mod.get_component<doir::lookup::function_return_type>(ft);

		if(mod.has_component<doir::block>(root)) {
			auto parameters = inputs.associated_parameters(mod, mod.get_component<doir::block>(root));

			out << "(";
			for(size_t i = 0; i < parameters.size(); ++i)
				print_impl(out, mod, parameters[i], pretty, debug) << (i < parameters.size() - 1 ? (pretty ? ", " : ",") : "");
			out << ")";

			if(return_type)
				out << (pretty ? " -> " : "->") << print_lookup_name(mod, *return_type, debug);
			if(debug)
				out << "[" << ft << "]";

			out << (pretty ? " = " : "=");
			print_block(out, mod, mod.get_component<doir::block>(root), pretty, debug, true, indent);
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

	} else if(mod.has_component<doir::block>(root)) {
		auto [ident, type, location, Export] = get_common_assignment_elements(mod, root, debug);
		out << indent_string << Export << ident << (pretty ? ": " : ":") << type << (pretty ? " = " : "=");
		print_block(out, mod, mod.get_component<doir::block>(root), pretty, debug, false, indent);

	} else out << "<type_of error>";
	return out;
}

std::ostream& print_impl(std::ostream& out, const doir::module& mod, ecrs::entity_t root, bool pretty, bool debug, size_t indent /*= 0*/) {
	auto indent_string = pretty ? "\t"_fpr.replicate(indent).auto_free() : ""_fpr;

	if(mod.has_component<doir::type_of>(root) || mod.has_component<doir::lookup::type_of>(root))
		print_type_of(out, mod, root, pretty, debug, indent);
	else if(mod.has_component<doir::type_definition>(root)) {
		auto [ident, type, location, Export] = get_common_assignment_elements(mod, root, debug);
		out << indent_string << Export << ident << (pretty ? ": " : ":") << type << (pretty ? " = " : "=");
		print_block(out, mod, mod.get_component<doir::block>(root), pretty, debug, false, indent);

	} else if(mod.has_component<doir::Namespace>(root)) {
		auto [ident, type, location, Export] = get_common_assignment_elements(mod, root, debug);
		out << indent_string << Export << ident << (pretty ? ": " : ":") << type << (pretty ? " = " : "=");
		print_block(out, mod, mod.get_component<doir::block>(root), pretty, debug, false, indent);

	} else if(mod.has_component<doir::alias>(root) || mod.has_component<doir::lookup::alias>(root)) {
		auto [ident, type, location, Export] = get_common_assignment_elements(mod, root, debug);
		auto alias = mod.has_component<doir::alias>(root)
			? doir::lookup::alias(mod.get_component<doir::alias>(root).related[0], mod.get_component<doir::alias>(root).file)
			: mod.get_component<doir::lookup::alias>(root);

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
