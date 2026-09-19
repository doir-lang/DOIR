/// Regenerates `mizu.doir` - the DOIR-level binding for every Mizu
/// instruction. Ported from mizu_gen/gen.cpp.
///
/// This has to be re-run whenever the Mizu dependency changes, because the
/// ids it bakes into the generated file are `doirLookup`'s, which are fixed
/// at *compile* time from Mizu's own module list (plus DOIR's four extra
/// instructions, which take the ids immediately after Mizu's - see
/// doir.mizu.instructions).
///
/// The names it emits are the C++ Mizu spellings (`debug_print`,
/// `load_immediate`, ...), not D's camelCase ones, so existing `.doir` sources
/// keep working; only the numeric ids change.
module tools.mizu_gen;

import core.stdc.stdio : printf;

import doir.mizu.instructions : doirLookup;
import mizu.lookup : notFound;

@nogc nothrow:


/// Every instruction to bind, in the order the generated file lists them.
/// These are `doirLookup` names (D spellings); `snakeCase` below converts
/// each one for the DOIR side.
private static immutable string[44] program = [
	"findLabel",
	"debugPrint",
	"debugPrintBinary",
	"halt",
	"convertToU64",
	"convertToU32",
	"convertToU16",
	"convertToU8",
	"stackLoadU64",
	"stackStoreU64",
	"stackLoadU32",
	"stackStoreU32",
	"stackLoadU16",
	"stackStoreU16",
	"stackLoadU8",
	"stackStoreU8",
	"stackPush",
	"stackPushImmediate",
	"stackPop",
	"stackPopImmediate",
	"offsetOfStackBottom",
	"jumpRelative",
	"jumpRelativeImmediate",
	"jumpTo",
	"branchRelative",
	"branchRelativeImmediate",
	"branchTo",
	"setIfEqual",
	"setIfNotEqual",
	"setIfLess",
	"setIfLessSigned",
	"setIfGreaterEqual",
	"setIfGreaterEqualSigned",
	"add",
	"subtract",
	"multiply",
	"divide",
	"modulus",
	"shiftLeft",
	"shiftRightLogical",
	"shiftRightArithmetic",
	"bitwiseXor",
	"bitwiseAnd",
	"bitwiseOr",
];

/// DOIR's own four, which the generated file nests in a `doir` namespace of
/// its own so they read as `mizu.doir.execute` rather than sitting beside
/// Mizu's instructions as `mizu.doir_execute`.
private static immutable string[4] doirProgram = [
	"setModule",
	"attachComptimeNumberI64",
	"execute",
	"executeIf",
];

private static immutable string[16] singleOperandOps = [
	"debugPrint", "debugPrintBinary", "convertToU64", "convertToU32", "convertToU16",
	"convertToU8", "stackLoadU64", "stackLoadU32", "stackLoadU16", "stackLoadU8",
	"stackPush", "stackPop", "offsetOfStackBottom", "jumpRelative", "jumpTo",
	"setModule",
];

private static immutable string[3] immediateOps = [
	"stackPushImmediate", "stackPopImmediate", "jumpRelativeImmediate",
];

private static immutable string[1] branchImmediateOps = ["branchRelativeImmediate"];

private bool isIn(const(string)[] set, const(char)[] name) {
	foreach (s; set) if (s == name) return true;
	return false;
}

/// `debugPrintBinary` -> `debug_print_binary`, `convertToU64` -> `convert_to_u64`.
/// Names that already contain `_` are passed through unchanged.
private size_t snakeCase(const(char)[] name, char[] buffer) {
	size_t n = 0;
	foreach (c; name) {
		if (c >= 'A' && c <= 'Z') {
			if (n > 0 && buffer[n - 1] != '_') buffer[n++] = '_';
			buffer[n++] = cast(char)(c - 'A' + 'a');
		} else buffer[n++] = c;
	}
	return n;
}

private __gshared size_t nextId = 0;

/// Emits one `%N : compiler.byte_pointer = "..."` plus the `emit_bytes` call
/// that writes it, for the little-endian bytes of `value`.
private void emitBytes(const(ubyte)[] bytes) {
	printf("\t%%%zu : compiler.byte_pointer = \"", nextId);
	foreach (b; bytes) printf("\\x%02x", b);
	printf("\"\n\t_ : compiler.byte = compiler.emit_bytes(%%%zu)\n", nextId);
	++nextId;
}

private void emitU64(ulong value) {
	emitBytes((cast(const(ubyte)*) &value)[0 .. ulong.sizeof]);
}

private void emitU32(uint value) {
	emitBytes((cast(const(ubyte)*) &value)[0 .. uint.sizeof]);
}

private void emitU16(ushort value) {
	emitBytes((cast(const(ubyte)*) &value)[0 .. ushort.sizeof]);
}

private void emitOpcodeId(const(char)[] name) {
	immutable id = doirLookup.lookupId(name);
	assert(id != notFound, "unknown instruction");
	emitU64(id);
}

private void printName(const(char)[] name) {
	char[64] buffer;
	immutable n = snakeCase(name, buffer);
	printf("%.*s", cast(int) n, buffer.ptr);
}

/// Emits one instruction's DOIR-level binding.
private void emitInstruction(const(char)[] name) {
	if (name == "findLabel") {
		printName(name); printf("_t : type = (label: compiler.assembler.register) -> u64\n");
		printf("_ : type = compiler.always_inline("); printName(name); printf("_t)\n");
		printName(name); printf(" : "); printName(name); printf("_t = {\n");
		printf("\tregret : compiler.assembler.register = compiler.assembler.return_register(u64)\n");
		emitOpcodeId(name);
		printf("\t_ : compiler.assembler.register = inline emit_register(regret)\n");
		printf("\tmask : compiler.pointer_sized = 0xFF\n");
		printf("\tlowest : compiler.byte = compiler.bitwise_and(label, mask)\n");
		printf("\t_ : compiler.byte = compiler.emit(lowest)\n");
		printf("\t%%8 : compiler.pointer_sized = 8\n");
		printf("\tshift_8 : compiler.pointer_sized = compiler.shift_right(label, %%8)\n");
		printf("\tlow : compiler.byte = compiler.bitwise_and(shift_8, mask)\n");
		printf("\t_ : compiler.byte = compiler.emit(low)\n");
		printf("\t%%16 : compiler.pointer_sized = 16\n");
		printf("\tshift_16 : compiler.pointer_sized = compiler.shift_right(label, %%16)\n");
		printf("\thigh : compiler.byte = compiler.bitwise_and(shift_16, mask)\n");
		printf("\t_ : compiler.byte = compiler.emit(high)\n");
		printf("\t%%24 : compiler.pointer_sized = 24\n");
		printf("\tshift_24 : compiler.pointer_sized = compiler.shift_right(label, %%24)\n");
		printf("\thighest : compiler.byte = compiler.bitwise_and(shift_24, mask)\n");
		printf("\t_ : compiler.byte = compiler.emit(highest)\n");
		emitU16(0);
		printf("\t_ : u64 = compiler.indicate_return(u64)\n}\n\n");

	} else if (name == "execute") {
		printName(name); printf(" : execute_t = {\n");
		printf("\trega : compiler.assembler.register = compiler.assembler.register_for(block, blk)\n");
		printf("\tregret : compiler.assembler.register = compiler.assembler.return_register(u64)\n");
		emitOpcodeId(name);
		printf("\t_ : compiler.assembler.register = inline emit_register(regret)\n");
		printf("\t_ : compiler.assembler.register = inline emit_register(rega)\n");
		emitU32(0);
		printf("\t_ : u64 = compiler.indicate_return(u64)\n}\n\n");

	} else if (name == "executeIf") {
		printName(name); printf(" : execute_if_t = {\n");
		printf("\trega : compiler.assembler.register = compiler.assembler.register_for(block, blk)\n");
		printf("\tregb : compiler.assembler.register = compiler.assembler.register_for(u64, condition)\n");
		printf("\tregret : compiler.assembler.register = compiler.assembler.return_register(u64)\n");
		emitOpcodeId(name);
		printf("\t_ : compiler.assembler.register = inline emit_register(regret)\n");
		printf("\t_ : compiler.assembler.register = inline emit_register(rega)\n");
		printf("\t_ : compiler.assembler.register = inline emit_register(regb)\n");
		emitU16(0);
		printf("\t_ : u64 = compiler.indicate_return(u64)\n}\n\n");

	} else if (name == "halt") {
		printName(name); printf(" : zero_parameters_t = {\n");
		emitOpcodeId(name);
		emitU64(0);
		printf("}\n\n");

	} else if (isIn(immediateOps, name)) {
		printName(name); printf(" : immediate_t = {\n");
		printf("\tregret : compiler.assembler.register = compiler.assembler.return_register(u64)\n");
		emitOpcodeId(name);
		printf("\t_ : compiler.assembler.register = inline emit_register(regret)\n");
		printf("\tmask : compiler.pointer_sized = 0xFF\n");
		printf("\tlowest : compiler.byte = compiler.bitwise_and(immediate, mask)\n");
		printf("\t_ : compiler.byte = compiler.emit(lowest)\n");
		printf("\t%%8 : compiler.pointer_sized = 8\n");
		printf("\tshift_8 : compiler.pointer_sized = compiler.shift_right(immediate, %%8)\n");
		printf("\tlow : compiler.byte = compiler.bitwise_and(shift_8, mask)\n");
		printf("\t_ : compiler.byte = compiler.emit(low)\n");
		printf("\t%%16 : compiler.pointer_sized = 16\n");
		printf("\tshift_16 : compiler.pointer_sized = compiler.shift_right(immediate, %%16)\n");
		printf("\thigh : compiler.byte = compiler.bitwise_and(shift_16, mask)\n");
		printf("\t_ : compiler.byte = compiler.emit(high)\n");
		printf("\t%%24 : compiler.pointer_sized = 24\n");
		printf("\tshift_24 : compiler.pointer_sized = compiler.shift_right(immediate, %%24)\n");
		printf("\thighest : compiler.byte = compiler.bitwise_and(shift_24, mask)\n");
		printf("\t_ : compiler.byte = compiler.emit(highest)\n");
		emitU16(0);
		printf("\t_ : u64 = compiler.indicate_return(u64)\n}\n\n");

	} else if (isIn(branchImmediateOps, name)) {
		printName(name); printf(" : branch_immediate_t = {\n");
		printf("\trega : compiler.assembler.register = compiler.assembler.register_for(u64, a)\n");
		printf("\tregret : compiler.assembler.register = compiler.assembler.return_register(u64)\n");
		emitOpcodeId(name);
		printf("\t_ : compiler.assembler.register = inline emit_register(regret)\n");
		printf("\t_ : compiler.assembler.register = inline emit_register(rega)\n");
		printf("\tmask : compiler.pointer_sized = 0xFF\n");
		printf("\tlow : compiler.byte = compiler.bitwise_and(immediate, mask)\n");
		printf("\t_ : compiler.byte = compiler.emit(low)\n");
		printf("\t%%8 : compiler.pointer_sized = 8\n");
		printf("\tshift_8 : compiler.pointer_sized = compiler.shift_right(immediate, %%8)\n");
		printf("\thigh : compiler.byte = compiler.bitwise_and(shift_8, mask)\n");
		printf("\t_ : compiler.byte = compiler.emit(high)\n");
		emitU16(0);
		printf("\t_ : u64 = compiler.indicate_return(u64)\n}\n\n");

	} else if (isIn(singleOperandOps, name)) {
		printName(name); printf(" : one_parameters_t = {\n");
		printf("\trega : compiler.assembler.register = compiler.assembler.register_for(u64, a)\n");
		printf("\tregret : compiler.assembler.register = compiler.assembler.return_register(u64)\n");
		emitOpcodeId(name);
		printf("\t_ : compiler.assembler.register = inline emit_register(regret)\n");
		printf("\t_ : compiler.assembler.register = inline emit_register(rega)\n");
		emitU32(0);
		printf("\t_ : u64 = compiler.indicate_return(u64)\n}\n\n");

	} else {
		printName(name); printf(" : two_parameters_t = {\n");
		printf("\trega : compiler.assembler.register = compiler.assembler.register_for(u64, a)\n");
		printf("\tregb : compiler.assembler.register = compiler.assembler.register_for(u64, b)\n");
		printf("\tregret : compiler.assembler.register = compiler.assembler.return_register(u64)\n");
		emitOpcodeId(name);
		printf("\t_ : compiler.assembler.register = inline emit_register(regret)\n");
		printf("\t_ : compiler.assembler.register = inline emit_register(rega)\n");
		printf("\t_ : compiler.assembler.register = inline emit_register(regb)\n");
		emitU16(0);
		printf("\t_ : u64 = compiler.indicate_return(u64)\n}\n\n");
	}
}

extern(C) int main(int argc, char** argv) @trusted {
	printf("mizu : namespace = {\n");
	printf("\n");
	printf("%%64 : compiler.pointer_sized = 64\n");
	printf("u64 : type = compiler.base_type(%%64, %%64)\n");
	printf("comptime : namespace = {\n");
	printf("\tu64 : type = compiler.comptime_base_type(%%64, %%64)\n");
	printf("}\n");
	printf("\n");
	printf("zero_parameters_t : type = () -> u64\n");
	printf("_ : type = compiler.always_inline(zero_parameters_t)\n");
	printf("one_parameters_t : type = (a : u64) -> u64\n");
	printf("_ : type = compiler.always_inline(one_parameters_t)\n");
	printf("two_parameters_t : type = (a : u64, b : u64) -> u64\n");
	printf("_ : type = compiler.always_inline(two_parameters_t)\n");
	printf("immediate_t : type = (immediate: comptime.u64) -> u64\n");
	printf("_ : type = compiler.always_inline(immediate_t)\n");
	printf("branch_immediate_t : type = (a: u64, immediate: comptime.u64) -> u64\n");
	printf("_ : type = compiler.always_inline(branch_immediate_t)\n");
	printf("\n");
	printf("execute_t : type = (blk: block) -> u64\n");
	printf("_ : type = compiler.always_inline(execute_t)\n");
	printf("execute_if_t : type = (blk: block, condition: u64) -> u64\n");
	printf("_ : type = compiler.always_inline(execute_if_t)\n");
	printf("\n");
	printf("emit_register_t : type = (r : compiler.assembler.register) -> compiler.assembler.register\n");
	printf("_ : type = compiler.always_inline(emit_register_t)\n");
	printf("emit_register : emit_register_t = {\n");
	printf("\t%%8 : compiler.pointer_sized = 8\n");
	printf("\tmask : compiler.pointer_sized = 0xFF\n");
	printf("\tshift : compiler.pointer_sized = compiler.shift_right(r, %%8)\n");
	printf("\tlow : compiler.byte = compiler.bitwise_and(r, mask)\n");
	printf("\t_ : compiler.byte = compiler.emit(low)\n");
	printf("\thigh : compiler.byte = compiler.bitwise_and(shift, mask)\n");
	printf("\t_ : compiler.byte = compiler.emit(high)\n");
	printf("\t_ : compiler.assembler.register = compiler.indicate_return(compiler.assembler.register)\n");
	printf("}\n");
	printf("\n\n");
	printf("load_immediate : (T : type, v : T) -> T = {}\n");
	printf("load_upper_immediate : (T : type, v : T) -> T = {}\n");
	printf("label : () -> compiler.assembler.register = {}\n");
	printf("\n");

	printf("load_immediate_op : (T : type) -> void = {\n");
	emitOpcodeId("loadImmediate");
	printf("\t_ : T = compiler.indicate_return(T)\n}\n");

	printf("load_upper_immediate_op : (T : type) -> void = {\n");
	emitOpcodeId("loadUpperImmediate");
	printf("\t_ : T = compiler.indicate_return(T)\n}\n");

	printf("label_op : () -> void = {\n");
	emitOpcodeId("label");
	printf("\t_ : void = compiler.indicate_return(void)\n}\n\n");

	foreach (name; program)
		emitInstruction(name);

	// DOIR's own four, namespaced so a program spells them
	// `mizu.doir.execute` and so on.
	printf("doir : namespace = {\n\n");
	foreach (name; doirProgram)
		emitInstruction(name);
	printf("}\n\n");

	printf("\n");
	foreach (i; 0 .. 257)
		printf("\tx%zu : compiler.assembler.register = %zu\n", cast(size_t) i, cast(size_t) i);

	printf("}\n");
	printf("\n_ : mizu.u64 = compiler.assembler.begin_register_allocation()\n\n");
	return 0;
}
