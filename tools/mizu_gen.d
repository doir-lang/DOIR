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

import doir.interface_ : Flags;
import doir.mizu.instructions : doirLookup;
import mizu.lookup : notFound;

@nogc nothrow:


/// Every instruction to bind, in the order the generated file lists them.
/// These are `doirLookup` names (D spellings); `snakeCase` below converts
/// each one for the DOIR side.
private static immutable string[92] program = [
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

	// `mizu.instructions.dbg`.
	"breakpoint",

	// `mizu.instructions.unsafe`. `copyMemory` and `setMemory` are left out:
	// both read `out_` as the *destination pointer* rather than writing a
	// result to it, and every binding here puts the assembler's return
	// register there. They need a shape of their own before they can be bound.
	"allocate",
	"freeAllocated",
	"allocateFatPointer",
	"freeFatPointer",
	"pointerToStack",
	"pointerToStackBottom",
	"pointerToRegister",

	// `mizu.instructions.f32`.
	"convertToF32",
	"convertSignedToF32",
	"convertFromF32",
	"convertSignedFromF32",
	"addF32",
	"subtractF32",
	"multiplyF32",
	"divideF32",
	"maxF32",
	"minF32",
	"sqrtF32",
	"setIfEqualF32",
	"setIfNotEqualF32",
	"setIfLessF32",
	"setIfGreaterEqualF32",
	"setIfNegativeF32",
	"setIfPositiveF32",
	"setIfInfinityF32",
	"setIfNanF32",

	// `mizu.instructions.f64`.
	"convertF32ToF64",
	"convertF64ToF32",
	"convertToF64",
	"convertSignedToF64",
	"convertFromF64",
	"convertSignedFromF64",
	"addF64",
	"subtractF64",
	"multiplyF64",
	"divideF64",
	"maxF64",
	"minF64",
	"sqrtF64",
	"setIfEqualF64",
	"setIfNotEqualF64",
	"setIfLessF64",
	"setIfGreaterEqualF64",
	"setIfNegativeF64",
	"setIfPositiveF64",
	"setIfInfinityF64",
	"setIfNanF64",
];

/// DOIR's own four, which the generated file nests in a `doir` namespace of
/// its own so they read as `mizu.doir.execute` rather than sitting beside
/// Mizu's instructions as `mizu.doir_execute`.
private static immutable string[37] doirProgram = [
	"setModule",
	"attachComptimeNumberI64",
	"execute",
	"executeIf",

	// The store, exposed to a comptime program - `standard.doir`'s `meta`,
	// `types`, `attribute` and `diagnostic` namespaces, which until now had
	// only a `compiler.*` spelling and so could not be implemented by a
	// program at all.
	"reflect",
	"unreflectAlias",
	"typeBase",
	"typeIs",
	"typeSizeBits",
	"typeAlignBits",
	"typeSetFlags",
	"typeComptime",
	"typeUnion",
	"typeNeverMonomorphize",
	"typeAlwaysInline",
	"typeAlwaysFlatten",
	"typeNoComptime",
	"typePure",
	"typeMakeUnique",
	"typeSetAttributeId",
	"typeAttributeId",
	"typePointer",
	"typeArray",
	"entityRename",
	"internName",
	"labelToImmediate",
	"sourceLocationFile",
	"sourceLocationStartByte",
	"sourceLocationEndByte",
	"sourceLocationStartLine",
	"sourceLocationStartColumn",
	"sourceLocationEndLine",
	"sourceLocationEndColumn",
	"diagnosticInfo",
	"diagnosticWarning",
	"diagnosticError",

	// Last, because `doirLookup` numbers by declaration order and the ids
	// below are baked into the generated file: a name inserted above this one
	// renumbers everything after it.
	"fieldOffsetBits",
];

private static immutable string[50] singleOperandOps = [
	"debugPrint", "debugPrintBinary", "convertToU64", "convertToU32", "convertToU16",
	"convertToU8", "stackLoadU64", "stackLoadU32", "stackLoadU16", "stackLoadU8",
	"stackPush", "stackPop", "offsetOfStackBottom", "jumpRelative", "jumpTo",
	"setModule",

	"allocate", "freeAllocated", "pointerToStack", "pointerToStackBottom",
	"pointerToRegister",

	"convertToF32", "convertSignedToF32", "convertFromF32", "convertSignedFromF32",
	"sqrtF32", "setIfNegativeF32", "setIfPositiveF32", "setIfInfinityF32", "setIfNanF32",

	"convertF32ToF64", "convertF64ToF32", "convertToF64", "convertSignedToF64",
	"convertFromF64", "convertSignedFromF64", "sqrtF64", "setIfNegativeF64",
	"setIfPositiveF64", "setIfInfinityF64", "setIfNanF64",

	"internName",
	"labelToImmediate", "sourceLocationFile", "sourceLocationStartByte",
	"sourceLocationEndByte", "sourceLocationStartLine", "sourceLocationStartColumn",
	"sourceLocationEndLine", "sourceLocationEndColumn",
];

/// `(T : type) -> type`: a modifier edits the type it is handed and yields an
/// alias to it (M-Flag), a constructor allocates (M-Ctor). The signature is the
/// same either way, which is why `standard.mizu.doir` can alias both straight
/// through with no body of its own.
private static immutable string[9] typeModifierOps = [
	"typeComptime", "typeUnion", "typeNeverMonomorphize", "typeAlwaysInline",
	"typeAlwaysFlatten", "typeNoComptime", "typePure", "typeMakeUnique", "typePointer",
];

/// `(T : deduced type, field : T) -> u64`: asks a *field* something.
///
/// `deduced` rather than a fixed parameter type because the argument is a
/// field of whatever type its aggregate declared it, and S-Struct compares
/// layouts - a `u64` parameter would take a 64 bit field and reject an 8 bit
/// one. D-Deduce solves `T` off the argument and asks nothing of its layout.
private static immutable string[1] fieldQueryOps = [
	"fieldOffsetBits",
];

/// `(T : type) -> u64`: asks a type something instead of editing it.
private static immutable string[4] typeQueryOps = [
	"typeIs", "typeSizeBits", "typeAlignBits", "typeAttributeId",
];

/// `(T : type, n : comptime.u64) -> type`.
private static immutable string[2] typeWithNumberOps = [
	"typeSetAttributeId", "typeArray",
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
	// Left commented out rather than dropped: printing the whole lowered
	// module is the first thing wanted when a backend pass misbehaves.
	"\t\t//debugPrint",
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

	} else if (name == "reflect") {
		tabs(); printName(name); printf(" : reflect_t = {\n");
		++indent;
		line("rega : compiler.assembler.register = compiler.assembler.register_for(type, T)");
		line("regret : compiler.assembler.register = compiler.assembler.return_register(u64)");
		emitOpcodeId(name);
		line("_ : compiler.assembler.register = inline emit_register(regret)");
		line("_ : compiler.assembler.register = inline emit_register(rega)");
		emitU32(0);
		line("_ : u64 = compiler.indicate_return(u64)");
		--indent;
		line("}");

	} else if (isIn(typeModifierOps, name)) {
		tabs(); printName(name); printf(" : type_modifier_t = {\n");
		++indent;
		line("rega : compiler.assembler.register = compiler.assembler.register_for(type, T)");
		line("regret : compiler.assembler.register = compiler.assembler.return_register(type)");
		emitOpcodeId(name);
		line("_ : compiler.assembler.register = inline emit_register(regret)");
		line("_ : compiler.assembler.register = inline emit_register(rega)");
		emitU32(0);
		line("_ : type = compiler.indicate_return(type)");
		--indent;
		line("}");

	} else if (isIn(fieldQueryOps, name)) {
		tabs(); printName(name); printf(" : field_query_t = {\n");
		++indent;
		line("rega : compiler.assembler.register = compiler.assembler.register_for(u64, field)");
		line("regret : compiler.assembler.register = compiler.assembler.return_register(u64)");
		emitOpcodeId(name);
		line("_ : compiler.assembler.register = inline emit_register(regret)");
		line("_ : compiler.assembler.register = inline emit_register(rega)");
		emitU32(0);
		line("_ : u64 = compiler.indicate_return(u64)");
		--indent;
		line("}");

	} else if (isIn(typeQueryOps, name)) {
		tabs(); printName(name); printf(" : type_query_t = {\n");
		++indent;
		line("rega : compiler.assembler.register = compiler.assembler.register_for(type, T)");
		line("regret : compiler.assembler.register = compiler.assembler.return_register(u64)");
		emitOpcodeId(name);
		line("_ : compiler.assembler.register = inline emit_register(regret)");
		line("_ : compiler.assembler.register = inline emit_register(rega)");
		emitU32(0);
		line("_ : u64 = compiler.indicate_return(u64)");
		--indent;
		line("}");

	} else if (isIn(typeWithNumberOps, name)) {
		tabs(); printName(name); printf(" : type_with_number_t = {\n");
		++indent;
		line("rega : compiler.assembler.register = compiler.assembler.register_for(type, T)");
		line("regb : compiler.assembler.register = compiler.assembler.register_for(comptime.u64, n)");
		line("regret : compiler.assembler.register = compiler.assembler.return_register(type)");
		emitOpcodeId(name);
		line("_ : compiler.assembler.register = inline emit_register(regret)");
		line("_ : compiler.assembler.register = inline emit_register(rega)");
		line("_ : compiler.assembler.register = inline emit_register(regb)");
		emitU16(0);
		line("_ : type = compiler.indicate_return(type)");
		--indent;
		line("}");

	} else if (name == "typeBase") {
		tabs(); printName(name); printf(" : base_type_t = {\n");
		++indent;
		line("rega : compiler.assembler.register = compiler.assembler.register_for(comptime.u64, size_bits)");
		line("regb : compiler.assembler.register = compiler.assembler.register_for(comptime.u64, align_bits)");
		line("regret : compiler.assembler.register = compiler.assembler.return_register(type)");
		emitOpcodeId(name);
		line("_ : compiler.assembler.register = inline emit_register(regret)");
		line("_ : compiler.assembler.register = inline emit_register(rega)");
		line("_ : compiler.assembler.register = inline emit_register(regb)");
		emitU16(0);
		line("_ : type = compiler.indicate_return(type)");
		--indent;
		line("}");

	} else if (name == "unreflectAlias") {
		tabs(); printName(name); printf(" : unreflect_alias_t = {\n");
		++indent;
		line("rega : compiler.assembler.register = compiler.assembler.register_for(u64, e)");
		line("regret : compiler.assembler.register = compiler.assembler.return_register(type)");
		emitOpcodeId(name);
		line("_ : compiler.assembler.register = inline emit_register(regret)");
		line("_ : compiler.assembler.register = inline emit_register(rega)");
		emitU32(0);
		line("_ : type = compiler.indicate_return(type)");
		--indent;
		line("}");

	} else if (name == "halt" || name == "breakpoint") {
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

/// The `Flags` bits `type_set_flags` takes, written out from the compiler's
/// own enum so a regeneration is what keeps the two in step - the same reason
/// the instruction ids above are generated rather than typed.
///
/// `standard.mizu.doir` spells every modifier as one of these, which is what
/// P1 (flags are a set, applying twice is applying once) buys: five modifiers,
/// one instruction, five constants.
private void emitFlagConstants() {
	static immutable struct Bit { string name; ushort value; }
	static immutable Bit[9] bits = [
		Bit("exported", Flags.Export),
		Bit("comptime", Flags.Comptime),
		Bit("always_comptime", Flags.AlwaysComptime),
		Bit("union", Flags.Union),
		Bit("pure", Flags.Pure),
		// `inline` and `flatten` are grammar keywords; these are the names
		// `standard.doir` gives the same two bits anyway.
		Bit("always_inline", Flags.Inline),
		Bit("always_flatten", Flags.Flatten),
		Bit("never_monomorphize", Flags.NeverMonomorphize),
		Bit("no_comptime", Flags.NoComptime),
	];

	line("flags : namespace = {");
	++indent;
	// `mizu.comptime.u64`, not `comptime.u64`: by R-Qual a dotted path resolves
	// its first segment outward through the scope chain, and `comptime` is one
	// of the constants in this very block.
	foreach (b; bits) {
		tabs();
		printf("%.*s : mizu.comptime.u64 = %u\n", cast(int) b.name.length, b.name.ptr, cast(uint) b.value);
	}
	--indent;
	line("}");
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

	line("// The two crossings between a register and the entity behind it. Every");
	line("// other reflection instruction below is plain `u64` in and `u64` out, so");
	line("// these are the only two the type system has to say anything about:");
	line("// `reflect` takes a `type` and hands back the entity id that was already");
	line("// in the register, `unreflect_alias` turns an entity back into a name for");
	line("// it (M-Flag's second half, and what makes a modifier a modifier).");
	line("reflect_t : type = (T : type) -> u64");
	line("_ : type = compiler.always_inline(reflect_t)");
	line("_ : type = compiler.never_monomorphize(reflect_t)");
	line("unreflect_alias_t : type = (e : u64) -> type");
	line("_ : type = compiler.always_inline(unreflect_alias_t)");
	line("_ : type = compiler.never_monomorphize(unreflect_alias_t)");
	line("base_type_t : type = (size_bits : comptime.u64, align_bits : comptime.u64) -> type");
	line("_ : type = compiler.always_inline(base_type_t)");
	line("_ : type = compiler.never_monomorphize(base_type_t)");
	line("// `standard.doir`'s `modifier_function` and `constructor_function`, which");
	line("// share a signature - one edits and one allocates, and only the");
	line("// instruction knows which.");
	line("type_modifier_t : type = (T : type) -> type");
	line("_ : type = compiler.always_inline(type_modifier_t)");
	line("_ : type = compiler.never_monomorphize(type_modifier_t)");
	line("type_query_t : type = (T : type) -> u64");
	line("_ : type = compiler.always_inline(type_query_t)");
	line("_ : type = compiler.never_monomorphize(type_query_t)");
	line("// Asks a *field* rather than a type, so `u64` in rather than `type` in:");
	line("// what the register carries is the field's entity, the same crossing");
	line("// every reflection instruction below makes. Plain `u64` rather than a");
	line("// `deduced` parameter matching the field's own type - which is what");
	line("// S-Struct would want - because a `deduced` parameter gives the function");
	line("// type a materialized parameter block, and a type carrying one does not");
	line("// take `type_comptime`. Every type in this layer is 64 bits wide, so");
	line("// there is nothing for S-Struct to reject here; a backend with narrower");
	line("// registers would need the deduced form and the fix behind it.");
	line("field_query_t : type = (field : u64) -> u64");
	line("_ : type = compiler.always_inline(field_query_t)");
	line("_ : type = compiler.never_monomorphize(field_query_t)");
	line("type_with_number_t : type = (T : type, n : comptime.u64) -> type");
	line("_ : type = compiler.always_inline(type_with_number_t)");
	line("_ : type = compiler.never_monomorphize(type_with_number_t)");
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
	line("// A Mizu immediate is 32 bits, so a value wider than that takes both");
	line("// instructions - and `load_upper_immediate` on its own would encode the");
	line("// *low* half of whatever it is handed, since the pass that expands it");
	line("// truncates. These two do the pair, picking the halves apart themselves:");
	line("// `load_u64_immediate` reads the value as an integer, `load_f64_immediate`");
	line("// as the bit pattern of the double, which is what a float immediate is.");
	line("load_u64_immediate : load_immediate_t = {}");
	line("load_f64_immediate : load_immediate_t = {}");
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

	// DOIR's own, namespaced so a program spells them `mizu.doir.execute`
	// and so on.
	blank();
	line("doir : namespace = {");
	++indent;
	foreach (i, name; doirProgram) {
		if (i) blank();
		emitInstruction(name);
	}
	blank();
	emitFlagConstants();
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
