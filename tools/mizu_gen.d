/// Regenerates `mizu.doir` - the DOIR-level binding for every Mizu
/// instruction, plus the lowering schedule that file installs. Ported from
/// mizu_gen/gen.cpp.
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
///
/// The output is byte-for-byte what `mizu.doir` holds, so a regeneration that
/// changes nothing else diffs as nothing.
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

/// The body of the `compiler.override_fallback_schedule` string the generated
/// file ends in - the mizu lowering schedule, written in the schedule syntax
/// `doir.systems` parses. `doir.pipeline.mizuSchedule` is the same list built
/// out of D combinators, and the two are meant to agree; where they do not,
/// this is the one a program that early_includes `mizu.doir` actually runs.
///
/// Lines are relative to the `schedule` declaration's own indentation, and an
/// empty one stays empty rather than picking up tabs.
private static immutable string[33] scheduleBody = [
	"\tsequential(",
	"\t\tdepthFirst(nameReuse),",
	"\t\tdepthFirst(functionArity),",
	"\t\t// The post-comptime half of the type system. Scheduled here rather",
	"\t\t// than by the compiler so a backend can say something else: drop",
	"\t\t// these two lines and nothing type checks, replace them and the",
	"\t\t// rules change with the backend.",
	"\t\t//",
	"\t\t// `foldBaseTypes` first: S-Struct compares two types by their layout,",
	"\t\t// and every builtin type is a `base_type` call until something folds",
	"\t\t// it. Without this line `typeCheck` reads no layout on either side and",
	"\t\t// so agrees with everything.",
	"\t\tbreadthFirst(foldBaseTypes),",
	"\t\tdepthFirst(typeCheck),",
	"\t\tdepthFirst(computeTypeProperties),",
	"\t\tdepthFirst(runSchedule),",
	"\t\trunRegisteredSchedules,",
	"",
	"\t\tapplyGlobally(sequential(",
	"\t\t\tsort,",
	"\t\t\tdepthFirst(pinRegisters),",
	"\t\t\tbreadthFirst(allocateRegisters),",
	"\t\t\tdepthFirst(pinRegisters)",
	"\t\t)),",
	"",
	"\t\tbreadthFirst(computeCompilerNamespace!false),",
	"\t\tdepthFirst(materializeImmediates),",
	"\t\tdepthFirst(materializeLabels),",
	"\t\tsorted(monomorphizeFunctions, false),",
	"\t\tbreadthFirst(inlineFunctions),",
	"\t\tbreadthFirst(computeCompilerNamespace!true),",
	"\t\tdebugPrint",
	"\t)",
];

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

/// Current output depth in tabs; `tabs` opens a line at it.
private __gshared int indent = 0;

private void tabs() {
	foreach (_; 0 .. indent) printf("\t");
}

private void blank() {
	printf("\n");
}

/// Emits one whole line at the current indentation.
private void line(const(char)* text) {
	tabs();
	printf("%s\n", text);
}

/// Emits one `%N : compiler.byte_pointer = "..."` plus the `emit_bytes` call
/// that writes it, for the little-endian bytes of `value`.
private void emitBytes(const(ubyte)[] bytes) {
	tabs();
	printf("%%%zu : compiler.byte_pointer = \"", nextId);
	foreach (b; bytes) printf("\\x%02x", b);
	printf("\"\n");
	tabs();
	printf("_ : compiler.byte = compiler.emit_bytes(%%%zu)\n", nextId);
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

/// The four-byte little-endian splat every immediate operand is emitted as:
/// truncate a byte off the bottom, shift, repeat. `source` is the register
/// holding the value.
private void emitImmediateSplat(const(char)* source) {
	tabs(); printf("lowest : compiler.byte = compiler.truncate_to_byte(%s)\n", source);
	line("_ : compiler.byte = compiler.emit(lowest)");
	line("%8 : compiler.pointer_sized = 8");
	tabs(); printf("shift_8 : compiler.pointer_sized = compiler.shift_right(%s, %%8)\n", source);
	line("low : compiler.byte = compiler.truncate_to_byte(shift_8)");
	line("_ : compiler.byte = compiler.emit(low)");
	line("%16 : compiler.pointer_sized = 16");
	tabs(); printf("shift_16 : compiler.pointer_sized = compiler.shift_right(%s, %%16)\n", source);
	line("high : compiler.byte = compiler.truncate_to_byte(shift_16)");
	line("_ : compiler.byte = compiler.emit(high)");
	line("%24 : compiler.pointer_sized = 24");
	tabs(); printf("shift_24 : compiler.pointer_sized = compiler.shift_right(%s, %%24)\n", source);
	line("highest : compiler.byte = compiler.truncate_to_byte(shift_24)");
	line("_ : compiler.byte = compiler.emit(highest)");
}

/// Emits one instruction's DOIR-level binding.
private void emitInstruction(const(char)[] name) {
	if (name == "findLabel") {
		tabs(); printName(name); printf("_t : type = (label: compiler.assembler.register) -> u64\n");
		tabs(); printf("_ : type = compiler.never_monomorphize("); printName(name); printf("_t)\n");
		tabs(); printf("_ : type = compiler.always_inline("); printName(name); printf("_t)\n");
		tabs(); printName(name); printf(" : "); printName(name); printf("_t = {\n");
		++indent;
		line("regret : compiler.assembler.register = compiler.assembler.return_register(u64)");
		emitOpcodeId(name);
		line("_ : compiler.assembler.register = inline emit_register(regret)");
		emitImmediateSplat("label");
		emitU16(0);
		line("_ : u64 = compiler.indicate_return(u64)");
		--indent;
		line("}");

	} else if (name == "execute") {
		tabs(); printName(name); printf(" : execute_t = {\n");
		++indent;
		line("rega : compiler.assembler.register = compiler.assembler.register_for(block, blk)");
		line("regret : compiler.assembler.register = compiler.assembler.return_register(u64)");
		emitOpcodeId(name);
		line("_ : compiler.assembler.register = inline emit_register(regret)");
		line("_ : compiler.assembler.register = inline emit_register(rega)");
		emitU32(0);
		line("_ : u64 = compiler.indicate_return(u64)");
		--indent;
		line("}");

	} else if (name == "executeIf") {
		tabs(); printName(name); printf(" : execute_if_t = {\n");
		++indent;
		line("rega : compiler.assembler.register = compiler.assembler.register_for(block, blk)");
		line("regb : compiler.assembler.register = compiler.assembler.register_for(u64, condition)");
		line("regret : compiler.assembler.register = compiler.assembler.return_register(u64)");
		emitOpcodeId(name);
		line("_ : compiler.assembler.register = inline emit_register(regret)");
		line("_ : compiler.assembler.register = inline emit_register(rega)");
		line("_ : compiler.assembler.register = inline emit_register(regb)");
		emitU16(0);
		line("_ : u64 = compiler.indicate_return(u64)");
		--indent;
		line("}");

	} else if (name == "halt") {
		tabs(); printName(name); printf(" : zero_parameters_t = {\n");
		++indent;
		emitOpcodeId(name);
		emitU64(0);
		--indent;
		line("}");

	} else if (isIn(immediateOps, name)) {
		tabs(); printName(name); printf(" : immediate_t = {\n");
		++indent;
		line("regret : compiler.assembler.register = compiler.assembler.return_register(u64)");
		emitOpcodeId(name);
		line("_ : compiler.assembler.register = inline emit_register(regret)");
		emitImmediateSplat("immediate");
		emitU16(0);
		line("_ : u64 = compiler.indicate_return(u64)");
		--indent;
		line("}");

	} else if (isIn(branchImmediateOps, name)) {
		tabs(); printName(name); printf(" : branch_immediate_t = {\n");
		++indent;
		line("rega : compiler.assembler.register = compiler.assembler.register_for(u64, a)");
		line("regret : compiler.assembler.register = compiler.assembler.return_register(u64)");
		emitOpcodeId(name);
		line("_ : compiler.assembler.register = inline emit_register(regret)");
		line("_ : compiler.assembler.register = inline emit_register(rega)");
		// Two bytes rather than `emitImmediateSplat`'s four: an instruction is
		// a fixed 16 bytes, and this one already spends two of them on a second
		// register.
		line("low : compiler.byte = compiler.truncate_to_byte(immediate)");
		line("_ : compiler.byte = compiler.emit(low)");
		line("%8 : compiler.pointer_sized = 8");
		line("shift_8 : compiler.pointer_sized = compiler.shift_right(immediate, %8)");
		line("high : compiler.byte = compiler.truncate_to_byte(shift_8)");
		line("_ : compiler.byte = compiler.emit(high)");
		emitU16(0);
		line("_ : u64 = compiler.indicate_return(u64)");
		--indent;
		line("}");

	} else if (isIn(singleOperandOps, name)) {
		tabs(); printName(name); printf(" : one_parameters_t = {\n");
		++indent;
		line("rega : compiler.assembler.register = compiler.assembler.register_for(u64, a)");
		line("regret : compiler.assembler.register = compiler.assembler.return_register(u64)");
		emitOpcodeId(name);
		line("_ : compiler.assembler.register = inline emit_register(regret)");
		line("_ : compiler.assembler.register = inline emit_register(rega)");
		emitU32(0);
		line("_ : u64 = compiler.indicate_return(u64)");
		--indent;
		line("}");

	} else {
		tabs(); printName(name); printf(" : two_parameters_t = {\n");
		++indent;
		line("rega : compiler.assembler.register = compiler.assembler.register_for(u64, a)");
		line("regb : compiler.assembler.register = compiler.assembler.register_for(u64, b)");
		line("regret : compiler.assembler.register = compiler.assembler.return_register(u64)");
		emitOpcodeId(name);
		line("_ : compiler.assembler.register = inline emit_register(regret)");
		line("_ : compiler.assembler.register = inline emit_register(rega)");
		line("_ : compiler.assembler.register = inline emit_register(regb)");
		emitU16(0);
		line("_ : u64 = compiler.indicate_return(u64)");
		--indent;
		line("}");
	}
}

/// The schedule declaration, as a `"""` string handed to
/// `compiler.run_schedule` here and to `compiler.override_fallback_schedule`
/// at the bottom of the file - the first runs it on `mizu.doir` itself, the
/// second makes it what every module that includes this one is lowered with.
private void emitSchedule() {
	line("schedule : compiler.byte_pointer = \"\"\"");
	foreach (l; scheduleBody) {
		if (l.length == 0) { blank(); continue; }
		tabs();
		printf("%.*s\n", cast(int) l.length, l.ptr);
	}
	line("\"\"\"");
	line("_ : compiler.pointer_sized = compiler.run_schedule(schedule)");
}

extern(C) int main(int argc, char** argv) @trusted {
	printf("mizu : namespace = {\n");
	blank();
	++indent;

	line("%64 : compiler.pointer_sized = 64");
	line("u64 : type = compiler.base_type(%64, %64)");
	line("comptime : namespace = {");
	++indent;
	line("u64 : type = compiler.comptime_base_type(%64, %64)");
	--indent;
	line("}");
	blank();

	line("zero_parameters_t : type = () -> u64");
	line("_ : type = compiler.always_inline(zero_parameters_t)");
	line("one_parameters_t : type = (a : u64) -> u64");
	line("_ : type = compiler.always_inline(one_parameters_t)");
	line("two_parameters_t : type = (a : u64, b : u64) -> u64");
	line("_ : type = compiler.always_inline(two_parameters_t)");
	line("// These three take a comptime parameter but have nothing to gain from a body");
	line("// of their own for each value of it: every copy would emit the same");
	line("// instruction with one immediate changed, and there are 2^64 immediates and");
	line("// 256 registers. `always_inline` already gives the call site the copy it");
	line("// wants; monomorphizing first would only make a declaration to inline from.");
	line("immediate_t : type = (immediate: comptime.u64) -> u64");
	line("_ : type = compiler.always_inline(immediate_t)");
	line("_ : type = compiler.never_monomorphize(immediate_t)");
	line("branch_immediate_t : type = (a: u64, immediate: comptime.u64) -> u64");
	line("_ : type = compiler.always_inline(branch_immediate_t)");
	line("_ : type = compiler.never_monomorphize(branch_immediate_t)");
	blank();

	line("// The block is comptime, but it is not decoration: `execute` and");
	line("// `execute_if` hand it to the VM's own instruction, so it has to stay an");
	line("// argument of the call. A comptime parameter that the callee *passes on* is");
	line("// exactly the case for this marker.");
	line("execute_t : type = (blk: block) -> u64");
	line("_ : type = compiler.always_inline(execute_t)");
	line("_ : type = compiler.never_monomorphize(execute_t)");
	line("execute_if_t : type = (blk: block, condition: u64) -> u64");
	line("_ : type = compiler.always_inline(execute_if_t)");
	line("_ : type = compiler.never_monomorphize(execute_if_t)");
	blank();

	line("emit_register_t : type = (r : compiler.assembler.register) -> compiler.assembler.register");
	line("_ : type = compiler.always_inline(emit_register_t)");
	line("_ : type = compiler.never_monomorphize(emit_register_t)");
	line("emit_register : emit_register_t = {");
	++indent;
	line("%8 : compiler.pointer_sized = 8");
	line("shift : compiler.pointer_sized = compiler.shift_right(r, %8)");
	line("low : compiler.byte = compiler.truncate_to_byte(r)");
	line("_ : compiler.byte = compiler.emit(low)");
	line("high : compiler.byte = compiler.truncate_to_byte(shift)");
	line("_ : compiler.byte = compiler.emit(high)");
	line("_ : compiler.assembler.register = compiler.indicate_return(compiler.assembler.register)");
	--indent;
	line("}");
	blank();
	blank();

	line("// Named rather than written inline at each declaration, so that");
	line("// `never_monomorphize` has something to be applied to: `T` is a comptime");
	line("// parameter, and every copy of these would emit the same instruction with");
	line("// one immediate changed.");
	line("load_immediate_t : type = (T : type, v : T) -> T");
	line("_ : type = compiler.never_monomorphize(load_immediate_t)");
	line("immediate_op_t : type = (T : type) -> void");
	line("_ : type = compiler.never_monomorphize(immediate_op_t)");
	blank();

	line("load_immediate : load_immediate_t = {}");
	line("load_upper_immediate : load_immediate_t = {}");
	line("label : () -> compiler.assembler.register = {}");
	blank();

	line("load_immediate_op : immediate_op_t = {");
	++indent;
	emitOpcodeId("loadImmediate");
	line("_ : T = compiler.indicate_return(T)");
	--indent;
	line("}");

	line("load_upper_immediate_op : immediate_op_t = {");
	++indent;
	emitOpcodeId("loadUpperImmediate");
	line("_ : T = compiler.indicate_return(T)");
	--indent;
	line("}");

	line("label_op : () -> void = {");
	++indent;
	emitOpcodeId("label");
	line("_ : void = compiler.indicate_return(void)");
	--indent;
	line("}");

	foreach (name; program) {
		blank();
		emitInstruction(name);
	}

	// DOIR's own four, namespaced so a program spells them
	// `mizu.doir.execute` and so on.
	blank();
	line("doir : namespace = {");
	++indent;
	foreach (i, name; doirProgram) {
		if (i) blank();
		emitInstruction(name);
	}
	--indent;
	line("}");
	blank();

	foreach (i; 0 .. 257) {
		tabs();
		printf("x%zu : compiler.assembler.register = %zu\n", cast(size_t) i, cast(size_t) i);
	}
	blank();

	emitSchedule();
	--indent;
	printf("}\n");
	blank();

	// The schedule again, as the fallback every including module inherits.
	printf("_ : compiler.pointer_sized = compiler.override_fallback_schedule(mizu.schedule)\n");
	printf("_ : mizu.u64 = compiler.assembler.begin_register_allocation()\n");
	return 0;
}
