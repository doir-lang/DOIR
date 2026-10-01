/// The Mizu instructions DOIR adds so a comptime-evaluated program can reach
/// back into the module that is compiling it. The first four are ported from
/// mizu_doir_instructions.hpp; the rest are the store operations
/// `standard.doir`'s `meta`, `types`, `attribute` and `diagnostic` namespaces
/// are made of, which had only a `compiler.*` spelling - a pass the schedule
/// runs - and so could not be called by a program at all.
///
/// The C++ registered these with Mizu at static-initialization time
/// (`MIZU_REGISTER_INSTRUCTION`), which let `mizu::from_portable` resolve
/// them by id. The D Mizu has no runtime registration: it builds its
/// instruction table at *compile* time, and `mizu.lookup.Lookup` lets a
/// project extend that table with modules of its own. `doirLookup` below is
/// that extension - Mizu's instructions with these appended, so Mizu's ids are
/// exactly what they would be without DOIR and ours start at
/// `doirLookup.builtinCount`.
///
/// This is the Mizu half of DOIR: a module Mizu's table template can be
/// handed. Note that the table stores fully qualified names, so these are
/// spelled `doir.mizu.instructions.*` in a portable-format program.
///
/// To serialize or load a program that uses these, pass the lookup to the
/// ordinary Mizu functions - `fromPortable!doirLookup(bytes)`,
/// `toBinary!doirLookup(program)` - instead of letting them default to
/// `Lookup!()`.
module doir.mizu.instructions;

import core.stdc.string : strlen;

static import fp.dynarray;
import fp.dynarray : daLength = length;

import mizu.lookup : Lookup;
import mizu.opcode;

import ecrs.storage : EntityId, invalidEntity;

import diagnose.diagnostics : Diagnostic, Kind, pushAnnotation;
import diagnose.source_location : SourceLocation;

import doir.diagnostics : DiagnosticType, diagnostics, pushDiagnostic;
import doir.interface_;
import doir.module_;
import doir.string_helpers : InternedString, text;

@nogc nothrow:

/// Mizu's instruction table plus the ones below.
alias doirLookup = Lookup!(doir.mizu.instructions);


/// Where the comptime evaluator pins the entity currently being evaluated.
/// TODO: Needs to be kept in sync with the location in the comptime
/// evaluation code.
enum Reg currentEntityReg = 2;

/// Where a program's `Module*` lives: one pointer below the stack bottom.
///
/// NOTE: the C++ writes (and reads) the pointer at `env->stack_bottom`
/// itself, which is one past the end of the environment's memory - an
/// out-of-bounds write that happens to work. `doir_set_module` there already
/// decrements `sp` by a pointer's width first, so this uses that slot, which
/// is in bounds and equally self-consistent.
private ulong** modulePointerSlot(RegistersAndStack* env) @trusted {
	return cast(ulong**)(env.stackBottom - (void*).sizeof);
}

private ref Module storedModule(RegistersAndStack* env) @trusted {
	return *cast(Module*)(*modulePointerSlot(env));
}


extern(C) void* setModule(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) @trusted {
	// Set module is expected to be run at the start of the program.
	assert(sp == env.stackBottom);

	sp -= (void*).sizeof;
	assert(sp > env.stackBoundary);
	assert(sp <= env.stackBottom);

	auto mod = cast(Module*) registers[pc.a];
	*modulePointerSlot(env) = cast(ulong*) mod;
	registers[pc.out_] = cast(size_t) mod;

	mixin(mizuNext);
}

extern(C) void* attachComptimeNumberI64(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) @trusted {
	auto mod = &storedModule(env);
	immutable e = cast(EntityId) registers[pc.a];
	auto out_ = &getOrAddComponent!ComptimeNumber(*mod, e);
	out_.value = registers[pc.b];
	registers[pc.out_] = cast(size_t) out_;

	mixin(mizuNext);
}

extern(C) void* execute(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) @trusted {
	auto mod = &storedModule(env);
	immutable e = cast(EntityId) registers[currentEntityReg];
	immutable blk = cast(EntityId) registers[pc.a];
	immutable type = getComponent!TypeOf(*mod, e).related[0];

	immutable copied = deepCopy(*mod, blk);

	stripValue(*mod, e);
	attachSubblock(*mod, e, type);
	inlineInto(*mod, copied, e, 0);

	registers[pc.out_] = e;

	mixin(mizuNext);
}

extern(C) void* executeIf(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) @trusted {
	auto mod = &storedModule(env);
	immutable e = cast(EntityId) registers[currentEntityReg];
	immutable blk = cast(EntityId) registers[pc.a];

	if (registers[pc.b]) {
		// If the condition is true we inline the block
		immutable type = getComponent!TypeOf(*mod, e).related[0];

		immutable copied = deepCopy(*mod, blk);

		stripValue(*mod, e);
		attachSubblock(*mod, e, type);
		inlineInto(*mod, copied, e, 0);
	} else {
		// Otherwise we erase this call from existence
		immutable parent = findParent(*mod, e);
		auto related = &getComponent!Block(*mod, parent).related;
		for (size_t i = daLength(*related); i-- > 0;)
			if ((*related)[i] == e)
				fp.dynarray.removeAt(*related, i);
	}

	registers[pc.out_] = e;

	mixin(mizuNext);
}


// ---------------------------------------------------------------------------
// Reflection: the entity store, exposed to a comptime program
// ---------------------------------------------------------------------------
//
// `standard.doir`'s `meta`, `types`, `attribute` and `diagnostic` namespaces
// are all store edits, and every one of them had only a `compiler.*` spelling
// - which is a pass the schedule runs, not something a program can call. These
// are the same edits as instructions, so `standard.mizu.doir` can implement
// that surface against `mizu.doir` alone.
//
// The protocol is `comptimeEvaluate`'s: an argument of type `type` or `block`
// reaches the VM as its *entity id*, a string constant as the address of its
// bytes, and anything else as its value. So every `entity` below is already in
// the register - `meta.entity` is `pointer_sized` for exactly this reason -
// and nothing here has to go looking for one.

/// The NUL-terminated string a `byte_pointer` argument points at. Both an
/// interned name and a `DString`'s buffer carry a terminator (see
/// `string_helpers.allocateText`), so the length the register cannot carry is
/// recoverable.
private const(char)[] stringArgument(ulong r) @trusted {
	auto p = cast(const(char)*) r;
	if (p is null) return null;
	return p[0 .. strlen(p)];
}

/// M-Flag's second half: the call being folded stops being a call and becomes
/// a name for `target`. Without this a modifier would be a call site holding a
/// number, and `_ : type = comptime(some_t)` would name nothing.
private void collapseToAlias(ref Module mod, EntityId call, EntityId target) {
	if (call == target) return;
	stripValue(mod, call);
	attachAlias(mod, call, target);
}

/// The entity `standard.doir` calls `location` - the call's own position,
/// which is what every `meta.source_location` query is asked about.
private SourceLocation locationOf(ref Module mod, EntityId e) {
	return findSourceLocation(mod, e);
}


extern(C) void* reflect(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) @trusted {
	// Identity: a `type` argument arrives as its entity id already. The
	// instruction exists so the crossing from `type` to `entity` is a call the
	// program makes rather than an annotation nothing checks - the same
	// argument `compiler.truncate_to_byte` settled for the byte narrowing.
	registers[pc.out_] = registers[pc.a];
	mixin(mizuNext);
}

extern(C) void* unreflectAlias(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) @trusted {
	auto mod = &storedModule(env);
	immutable e = cast(EntityId) registers[currentEntityReg];
	immutable target = cast(EntityId) registers[pc.a];

	collapseToAlias(*mod, e, target);
	registers[pc.out_] = target;

	mixin(mizuNext);
}

/// A base type - a size and an alignment in bits and nothing else - allocated
/// on the call, the way `typePointer` below allocates a pointer.
///
/// `compiler.base_type` is the only other way to make one, and an assembler
/// layer written against `mizu.doir` alone cannot reach it. Without this,
/// `standard.doir`'s `u1` and `u8` have nothing to be built out of: Mizu
/// exposes one type, `u64`, and no way to say what a narrower one is.
///
/// The discriminator stays zero - `opt.nextUnique`'s answer - so comparison is
/// structural (S-Struct) unless `typeMakeUnique` says otherwise.
extern(C) void* typeBase(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) @trusted {
	auto mod = &storedModule(env);
	immutable call = cast(EntityId) registers[currentEntityReg];

	stripValue(*mod, call);
	attachType(*mod, call);
	auto def = &getComponent!TypeDefinition(*mod, call);
	def.size = cast(size_t) registers[pc.a];
	def.alignment = cast(size_t) registers[pc.b];
	def.unique = BuiltinUnique.structural;
	// C-Type: a type is compile time known, and `buildBuiltinBlock` says so of
	// every builtin the same way.
	getOrAddComponent!Flags(*mod, call).flags |= Flags.Comptime | Flags.AlwaysComptime;
	registers[pc.out_] = call;

	mixin(mizuNext);
}

extern(C) void* typeIs(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) @trusted {
	auto mod = &storedModule(env);
	immutable e = resolveAlias(*mod, cast(EntityId) registers[pc.a]);
	registers[pc.out_] = hasComponent!TypeDefinition(*mod, e) ? 1 : 0;
	mixin(mizuNext);
}

extern(C) void* typeSizeBits(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) @trusted {
	auto mod = &storedModule(env);
	immutable e = resolveAlias(*mod, cast(EntityId) registers[pc.a]);
	registers[pc.out_] = hasComponent!TypeDefinition(*mod, e)
		? getComponent!TypeDefinition(*mod, e).size : 0;
	mixin(mizuNext);
}

extern(C) void* typeAlignBits(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) @trusted {
	auto mod = &storedModule(env);
	immutable e = resolveAlias(*mod, cast(EntityId) registers[pc.a]);
	registers[pc.out_] = hasComponent!TypeDefinition(*mod, e)
		? getComponent!TypeDefinition(*mod, e).alignment : 0;
	mixin(mizuNext);
}

/// M-Flag, the generic form: the bit comes from a register, which is what
/// `meta.types` wants - it is the unchecked half of the interface and works in
/// entities rather than types.
///
/// P3: the flag lands on `resolveAlias`'s answer, so it acts *through*
/// aliases, which is what makes `pack(byte)` reach `u8` itself.
private void setFlagsAndAlias(Opcode* pc, ulong* registers, RegistersAndStack* env, ushort bits) @trusted {
	auto mod = &storedModule(env);
	immutable call = cast(EntityId) registers[currentEntityReg];
	immutable target = resolveAlias(*mod, cast(EntityId) registers[pc.a]);

	getOrAddComponent!Flags(*mod, target).flags |= bits;

	collapseToAlias(*mod, call, target);
	registers[pc.out_] = target;
}

extern(C) void* typeSetFlags(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) @trusted {
	setFlagsAndAlias(pc, registers, env, cast(ushort) registers[pc.b]);
	mixin(mizuNext);
}

// The checked half, one instruction per bit. Five instructions where one and a
// constant would do, because a DOIR function cannot *return* without the
// assembler layer (`compiler.indicate_return`), so anything the standard
// interface exposes above that layer has to be an alias to a primitive of the
// same arity rather than a one-line wrapper around a generic one. P1 makes
// each of them idempotent for free.

extern(C) void* typeComptime(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) @trusted {
	setFlagsAndAlias(pc, registers, env, Flags.Comptime);
	mixin(mizuNext);
}

extern(C) void* typeUnion(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) @trusted {
	setFlagsAndAlias(pc, registers, env, Flags.Union);
	mixin(mizuNext);
}

extern(C) void* typeNeverMonomorphize(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) @trusted {
	setFlagsAndAlias(pc, registers, env, Flags.NeverMonomorphize);
	mixin(mizuNext);
}

extern(C) void* typeAlwaysInline(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) @trusted {
	setFlagsAndAlias(pc, registers, env, Flags.Inline);
	mixin(mizuNext);
}

extern(C) void* typeAlwaysFlatten(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) @trusted {
	setFlagsAndAlias(pc, registers, env, Flags.Flatten);
	mixin(mizuNext);
}

/// The one flag that says a call *cannot* be folded, rather than that it can.
/// `sema.bubbleComptime` reads it off the function type, so a code emitting
/// function is not dragged onto the VM by a caller whose arguments happen to be
/// constants.
extern(C) void* typeNoComptime(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) @trusted {
	setFlagsAndAlias(pc, registers, env, Flags.NoComptime);
	mixin(mizuNext);
}

extern(C) void* typePure(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) @trusted {
	setFlagsAndAlias(pc, registers, env, Flags.Pure);
	mixin(mizuNext);
}

/// M-Unique, and the one modifier that does *not* follow aliases: it edits the
/// entity it is handed, severing the alias link and giving it a discriminator
/// of its own. Following the alias here would modify the target and invert the
/// purpose - `unique(my_handle)` would make `index` itself a new type.
extern(C) void* typeMakeUnique(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) @trusted {
	auto mod = &storedModule(env);
	immutable call = cast(EntityId) registers[currentEntityReg];

	// Read off the call rather than out of `pc.a`: `opt.mizu.comptimeEvaluate`
	// resolves an argument's aliases before loading it into a register, which
	// is right for every other instruction here and fatal for this one - it
	// would hand over `index` where the program wrote `my_handle`, and editing
	// `index` is exactly what M-Unique exists not to do.
	immutable named = hasComponent!FunctionInputs(*mod, call)
		&& daLength(getComponent!FunctionInputs(*mod, call).related) > 0
		? getComponent!FunctionInputs(*mod, call).related[0]
		: cast(EntityId) registers[pc.a];
	immutable target = resolveAlias(*mod, named);

	// Same layout, fresh discriminator: S-Struct compares
	// <size, alignment, unique>, so this is what stops it converting to what it
	// used to be. `opt.nextUnique` hands every `base_type` a zero and reserves
	// the rest for here.
	if (hasComponent!Alias(*mod, named)) removeComponent!Alias(*mod, named);

	auto def = &getOrAddComponent!TypeDefinition(*mod, named);
	if (named != target && hasComponent!TypeDefinition(*mod, target)) {
		def.size = getComponent!TypeDefinition(*mod, target).size;
		def.alignment = getComponent!TypeDefinition(*mod, target).alignment;
	}
	def.unique = named;

	// A `TypeDefinition` with neither a `Block` nor a `Pointer` is read as a
	// function type (`doir.print`, and the layout pass agrees), so the severed
	// entity needs a structure of its own. A pointer is copied; anything else
	// becomes an opaque type of the size just recorded - its *fields* are not
	// copied, which costs nothing while every type in `standard.doir` is a base
	// type or a pointer, and is the thing to fix first when one is not.
	if (!hasComponent!Block(*mod, named) && !hasComponent!Pointer(*mod, named)) {
		if (hasComponent!Pointer(*mod, target))
			addComponent!Pointer(*mod, named) = getComponent!Pointer(*mod, target);
		else addComponent!Block(*mod, named);
		getOrAddComponent!Flags(*mod, named).flags |= Flags.Freestanding;
	}

	getOrAddComponent!Flags(*mod, named).flags |= Flags.Comptime | Flags.AlwaysComptime;

	collapseToAlias(*mod, call, named);
	registers[pc.out_] = named;

	mixin(mizuNext);
}

/// M-Attr: records which component slot stores this type.
extern(C) void* typeSetAttributeId(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) @trusted {
	auto mod = &storedModule(env);
	immutable call = cast(EntityId) registers[currentEntityReg];
	immutable target = resolveAlias(*mod, cast(EntityId) registers[pc.a]);

	getOrAddComponent!AttributeId(*mod, target).id = cast(size_t) registers[pc.b];

	collapseToAlias(*mod, call, target);
	registers[pc.out_] = target;

	mixin(mizuNext);
}

/// The attribute slot a type was pinned to, or zero for one that never was.
extern(C) void* typeAttributeId(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) @trusted {
	auto mod = &storedModule(env);
	immutable e = resolveAlias(*mod, cast(EntityId) registers[pc.a]);
	registers[pc.out_] = hasComponent!AttributeId(*mod, e)
		? getComponent!AttributeId(*mod, e).id : 0;
	mixin(mizuNext);
}

/// M-Ctor. A constructor allocates rather than edits - but the entity it
/// allocates is the *call*, exactly as `opt.computeCompilerNamespace` does for
/// `compiler.pointer`. A fresh `addEntity` would have no `Parent`, and
/// `canon.sort` renumbers by walking parents.
extern(C) void* typePointer(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) @trusted {
	auto mod = &storedModule(env);
	immutable call = cast(EntityId) registers[currentEntityReg];
	immutable base = resolveAlias(*mod, cast(EntityId) registers[pc.a]);

	stripValue(*mod, call);
	attachPointer(*mod, call, base);
	registers[pc.out_] = call;

	mixin(mizuNext);
}

/// Ditto, with the element count carried on the `Pointer` - "a pointer that
/// knows its length", as `standard.doir` puts it.
extern(C) void* typeArray(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) @trusted {
	auto mod = &storedModule(env);
	immutable call = cast(EntityId) registers[currentEntityReg];
	immutable base = resolveAlias(*mod, cast(EntityId) registers[pc.a]);

	stripValue(*mod, call);
	attachPointer(*mod, call, base, cast(size_t) registers[pc.b]);
	registers[pc.out_] = call;

	mixin(mizuNext);
}

/// `std.functions.abi_rename`: the emitted name, and nothing else about the
/// entity, changes.
extern(C) void* entityRename(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) @trusted {
	auto mod = &storedModule(env);
	immutable call = cast(EntityId) registers[currentEntityReg];
	immutable target = resolveAlias(*mod, cast(EntityId) registers[pc.a]);

	getOrAddComponent!Name(*mod, target).value = internIn(*mod, stringArgument(registers[pc.b]));

	collapseToAlias(*mod, call, target);
	registers[pc.out_] = target;

	mixin(mizuNext);
}

/// The interned address of a name, which is a stable id for it: interning is
/// what makes every name comparison in the compiler a pointer comparison, so
/// two spellings of one name already answer this identically.
extern(C) void* internName(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) @trusted {
	auto mod = &storedModule(env);
	registers[pc.out_] = cast(size_t) internIn(*mod, stringArgument(registers[pc.a])).view.ptr;
	mixin(mizuNext);
}

/// `mizu.instructions.core.label2immediate`, reachable from a program.
///
/// Mizu's `label` and `find_label` take a 32 bit immediate and only the first
/// four characters of a name survive into it; `std.label` and
/// `std.find_label` take the name. `opt.mizu.materializeLabels` folds one into
/// the other compiler-side, which a program written against `mizu.doir` alone
/// cannot reach.
extern(C) void* labelToImmediate(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) @trusted {
	import mizu.instructions.core : label2immediate;
	registers[pc.out_] = label2immediate(stringArgument(registers[pc.a]));
	mixin(mizuNext);
}


// --- source locations -------------------------------------------------------

extern(C) void* sourceLocationFile(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) @trusted {
	auto mod = &storedModule(env);
	auto location = locationOf(*mod, cast(EntityId) registers[pc.a]);
	// Interned so the pointer outlives this instruction and is NUL terminated,
	// which is what `null_terminated_byte_pointer` promises its caller.
	registers[pc.out_] = cast(size_t) internIn(*mod, location.file).view.ptr;
	mixin(mizuNext);
}

extern(C) void* sourceLocationStartByte(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) @trusted {
	auto mod = &storedModule(env);
	registers[pc.out_] = locationOf(*mod, cast(EntityId) registers[pc.a]).startByte;
	mixin(mizuNext);
}

extern(C) void* sourceLocationEndByte(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) @trusted {
	auto mod = &storedModule(env);
	registers[pc.out_] = locationOf(*mod, cast(EntityId) registers[pc.a]).endByte;
	mixin(mizuNext);
}

extern(C) void* sourceLocationStartLine(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) @trusted {
	auto mod = &storedModule(env);
	auto location = locationOf(*mod, cast(EntityId) registers[pc.a]);
	registers[pc.out_] = location.startLine(sourceOf(*mod, location));
	mixin(mizuNext);
}

extern(C) void* sourceLocationStartColumn(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) @trusted {
	auto mod = &storedModule(env);
	auto location = locationOf(*mod, cast(EntityId) registers[pc.a]);
	registers[pc.out_] = location.startColumn(sourceOf(*mod, location));
	mixin(mizuNext);
}

extern(C) void* sourceLocationEndLine(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) @trusted {
	auto mod = &storedModule(env);
	auto location = locationOf(*mod, cast(EntityId) registers[pc.a]);
	registers[pc.out_] = location.endLine(sourceOf(*mod, location));
	mixin(mizuNext);
}

extern(C) void* sourceLocationEndColumn(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) @trusted {
	auto mod = &storedModule(env);
	auto location = locationOf(*mod, cast(EntityId) registers[pc.a]);
	registers[pc.out_] = location.endColumn(sourceOf(*mod, location));
	mixin(mizuNext);
}


// --- diagnostics ------------------------------------------------------------
//
// Three instructions rather than one with the severity in `pc.b`: an `Opcode`
// has `out_`, `a` and `b` and nothing else, and the message and the entity to
// point at have already spent both operands. `standard.doir`'s `help` string
// is the parameter that does not fit; see `<divergences>`.

private void emitDiagnostic(ref Module mod, EntityId at, Kind kind, ulong message) @trusted {
	auto location = findDetailedSourceLocation(mod, at);
	auto diag = &pushDiagnostic(DiagnosticType.InvalidFunctionCall,
		location, sourceOf(mod, location), location.file);
	diag.kind = kind;

	Diagnostic.Annotation annotation;
	annotation.message = text(stringArgument(message));
	annotation.position = diag.location.start;
	pushAnnotation(*diag, annotation);
}

extern(C) void* diagnosticInfo(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) @trusted {
	auto mod = &storedModule(env);
	emitDiagnostic(*mod, cast(EntityId) registers[pc.b], Kind.info, registers[pc.a]);
	registers[pc.out_] = 0;
	mixin(mizuNext);
}

extern(C) void* diagnosticWarning(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) @trusted {
	auto mod = &storedModule(env);
	emitDiagnostic(*mod, cast(EntityId) registers[pc.b], Kind.warning, registers[pc.a]);
	registers[pc.out_] = 0;
	mixin(mizuNext);
}

extern(C) void* diagnosticError(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) @trusted {
	auto mod = &storedModule(env);
	emitDiagnostic(*mod, cast(EntityId) registers[pc.b], Kind.error, registers[pc.a]);
	registers[pc.out_] = 0;
	mixin(mizuNext);
}


// --- layout -----------------------------------------------------------------

/// Where a field begins inside the aggregate that declares it, in bits.
///
/// The register holds the field's *entity*, not a value - a field names a
/// position in a layout and has nothing to read at runtime - which is why
/// `opt.mizu.comptimeEvaluate` passes an aggregate field the way it passes a
/// type. `sema.fieldOffsetBits` is the answer, read off the `FieldOffset` that
/// `sema.computeTypeProperties` wrote while laying the type out; `0` for
/// anything that is not a field, which is all a register can say.
extern(C) void* fieldOffsetBits(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) @trusted {
	import doir.pipeline.sema.type_properties : offsetOf = fieldOffsetBits;

	auto mod = &storedModule(env);
	immutable e = resolveAlias(*mod, cast(EntityId) registers[pc.a]);
	immutable offset = offsetOf(*mod, e);
	registers[pc.out_] = offset == size_t.max ? 0 : offset;
	mixin(mizuNext);
}


// --- call sites -------------------------------------------------------------

/// How many arguments a call was given, and which declaration the i'th one
/// names.
///
/// What makes these worth an instruction rather than a pass: a construct that
/// has to emit *per argument* - the calling convention's marshalling, where one
/// move per argument lands in the register that argument's position asks for -
/// cannot be written in DOIR at all without them, because a call's argument
/// list is not something a callee can name. `argument` hands back an entity
/// because an argument *is* a register name (WF-Arg): the declaration is the
/// only thing there is to return.
///
/// `FunctionInputs` is a call's argument list and a function type's parameter
/// list both, so one pair of instructions answers for either - which is what
/// lets the same unroll walk a signature and the call matched against it.
///
/// Declared last on purpose: `doirLookup` numbers these by declaration order,
/// and `mizu.doir` bakes those numbers in, so anything inserted above here
/// renumbers every instruction below it.
extern(C) void* argumentCount(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) @trusted {
	auto mod = &storedModule(env);
	immutable e = resolveAlias(*mod, cast(EntityId) registers[pc.a]);
	registers[pc.out_] = hasComponent!FunctionInputs(*mod, e)
		? daLength(getComponent!FunctionInputs(*mod, e).related) : 0;
	mixin(mizuNext);
}

/// `invalidEntity` for an index past the end, which is what a register can say
/// - the same answer the type queries give for a non-type. A caller that got
/// its bound from `argumentCount` cannot see it.
extern(C) void* argument(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) @trusted {
	auto mod = &storedModule(env);
	immutable e = resolveAlias(*mod, cast(EntityId) registers[pc.a]);
	immutable index = cast(size_t) registers[pc.b];

	registers[pc.out_] = invalidEntity;
	if (hasComponent!FunctionInputs(*mod, e)) {
		auto inputs = &getComponent!FunctionInputs(*mod, e);
		if (index < daLength(inputs.related))
			registers[pc.out_] = resolveAlias(*mod, inputs.related[index]);
	}

	mixin(mizuNext);
}

/// The i'th parameter *declaration* of a function, or of its type.
///
/// `argument`'s counterpart, and not a special case of it: `FunctionInputs` on
/// a function type holds the parameter *types*, and a type does not carry
/// `FunctionParameter.index`. That index is the whole of the argument
/// convention - `opt.assignTemporaries` turns it into `-(index + 1)` and
/// `opt.mapTemporaries` reads the machine's argument class at that position -
/// so a caller that unites an argument's temporary with this declaration's has
/// said "this goes where argument i goes" without naming a register, and
/// without the convention being written down twice.
///
/// Searched rather than indexed, because a block lists a function's parameters
/// among its statements and nothing promises they come first or in order.
extern(C) void* parameter(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) @trusted {
	static EntityId findIn(ref Module mod, EntityId block, size_t index) {
		if (block == invalidEntity || !hasComponent!Block(mod, block)) return invalidEntity;
		auto related = &getComponent!Block(mod, block).related;
		foreach (i; 0 .. daLength(*related)) {
			immutable child = (*related)[i];
			if (!hasComponent!FunctionParameter(mod, child)) continue;
			if (getComponent!FunctionParameter(mod, child).index == index) return child;
		}
		return invalidEntity;
	}

	/// By `Parent`, which is the relation that actually holds a parameter to
	/// the thing it parameterizes - `typeAtCallSite` matches them that way
	/// too. The block walk above is the fast path and misses the case where a
	/// function *type* owns its parameters without being a block at all.
	static EntityId findByParent(ref Module mod, EntityId owner, size_t index) {
		if (owner == invalidEntity) return invalidEntity;
		immutable count = entityCount(mod);
		foreach (i; 0 .. count) {
			immutable e = cast(EntityId) i;
			if (!entityExists(mod, e)) continue;
			if (!hasComponent!FunctionParameter(mod, e)) continue;
			if (getComponent!FunctionParameter(mod, e).index != index) continue;
			if (!hasComponent!Parent(mod, e)) continue;
			if (getComponent!Parent(mod, e).related[0] == owner) return e;
		}
		return invalidEntity;
	}

	auto mod = &storedModule(env);
	immutable f = resolveAlias(*mod, cast(EntityId) registers[pc.a]);
	immutable index = cast(size_t) registers[pc.b];

	immutable ft = hasComponent!TypeOf(*mod, f)
		? resolveAlias(*mod, getComponent!TypeOf(*mod, f).related[0]) : invalidEntity;

	// A function lists its parameters among its own statements; a function type
	// owns them through `Parent`. Either is a fair thing to be handed, so both
	// get a turn - and then the lifted body, which is where the parameters
	// actually are by the time the calling convention asks: `pass_arguments`
	// runs after `opt.liftFunctionBodies`, which moves the body (parameters
	// and all) out from under the function and retargets their `Parent` to it,
	// so neither of the first two lookups nor a `Parent` search against the
	// function finds anything at all.
	auto found = findIn(*mod, f, index);
	if (found == invalidEntity) found = findIn(*mod, ft, index);
	if (found == invalidEntity) found = findByParent(*mod, f, index);
	if (found == invalidEntity) found = findByParent(*mod, ft, index);
	if (found == invalidEntity) found = findIn(*mod, liftedBodyOf(*mod, f), index);

	registers[pc.out_] = found;
	mixin(mizuNext);
}


// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
//
// These four run on the Mizu VM, inside the comptime evaluator, so the only
// way to reach them is to compile a program that calls them - which means
// pulling in `mizu.doir`, the generated file that binds every Mizu
// instruction (including these) at the DOIR level.

version (unittest) {
	static import fp.dynarray;

	import doir.diagnostics : diagnostics;
	import doir.parser : parseSource;
	import doir.pipeline : runPipeline;

	/// Compiles `body_` with `mizu.doir` early-included ahead of it, the way
	/// `test.doir` does, and reports whether the compile succeeded.
	private bool compileWithMizu(const(char)[] body_, ref Module mod, out EntityId root) @trusted {
		import fp.string : strFree = free, strSlice = slice;

		import doir.string_helpers : text;

		diagnostics().clear();
		mod = createModule();

		auto builders = createBuilderStack(mod);
		scope(exit) fp.dynarray.free(builders);

		auto source = text(
			"path : compiler.byte_pointer = \"./mizu.doir\"\n"
			~ "_ : compiler.byte = early_include(path)\n"
			~ "u64 : alias = mizu.u64\n", body_);
		scope(exit) strFree(source);

		assert(parseSource(mod, builders, strSlice(source), "instructions.doir"));
		root = runPipeline(mod, builders);
		return root != invalidEntity && !diagnostics().hasErrors();
	}
}

unittest {
	// `mizu.doir.execute` inlines a quoted block into the call that ran it,
	// unconditionally: the call entity comes back carrying the block's
	// contents rather than the call.
	Module mod;
	EntityId root;
	scope(exit) freeModule(mod);

	assert(compileWithMizu(
		"blk : block = {\n"
		~ "\tinlined : u64 = 1234\n"
		~ "}\n"
		~ "ran : u64 = mizu.doir.execute(blk)\n", mod, root));

	immutable ran = resolveLookupName(mod, internIn(mod, "ran"), root);
	assert(ran != invalidEntity);
	assert(hasComponent!Block(mod, ran));
	assert(!hasComponent!Call(mod, ran));
	diagnostics().clear();
}

unittest { // `mizu.doir.execute_if` does the same when its condition is true...
	Module mod;
	EntityId root;
	scope(exit) freeModule(mod);

	assert(compileWithMizu(
		"blk : block = {\n"
		~ "\tinlined : u64 = 1234\n"
		~ "}\n"
		~ "yes : u64 = 1\n"
		~ "ran : u64 = mizu.doir.execute_if(blk, yes)\n", mod, root));

	immutable ran = resolveLookupName(mod, internIn(mod, "ran"), root);
	assert(ran != invalidEntity);
	assert(hasComponent!Block(mod, ran));
	diagnostics().clear();
}

unittest { // ...and erases the call entirely when it is false
	Module mod;
	EntityId root;
	scope(exit) freeModule(mod);

	assert(compileWithMizu(
		"blk : block = {\n"
		~ "\tinlined : u64 = 1234\n"
		~ "}\n"
		~ "no : u64 = 0\n"
		~ "skipped : u64 = mizu.doir.execute_if(blk, no)\n", mod, root));

	assert(resolveLookupName(mod, internIn(mod, "skipped"), root) == invalidEntity);
	diagnostics().clear();
}

unittest { // M-Flag: the modifier sets the bit and collapses into an alias to its target
	Module mod;
	EntityId root;
	scope(exit) freeModule(mod);

	assert(compileWithMizu(
		"%8 : mizu.comptime.u64 = 8\n"
		~ "byte : type = mizu.doir.type_base(%8, %8)\n"
		~ "named : type = mizu.doir.type_comptime(byte)\n", mod, root));

	immutable byte_ = resolveLookupName(mod, internIn(mod, "byte"), root);
	assert(byte_ != invalidEntity);
	assert(getComponent!TypeDefinition(mod, byte_).size == 8);
	assert(flagsSet(mod, byte_, Flags.Comptime));

	// The call is a second name for what it edited, not a value of its own.
	immutable named = resolveLookupName(mod, internIn(mod, "named"), root);
	assert(resolveAlias(mod, named) == byte_);
	diagnostics().clear();
}

unittest { // P3: a modifier acts *through* an alias, so the target is what changes
	Module mod;
	EntityId root;
	scope(exit) freeModule(mod);

	assert(compileWithMizu(
		"%8 : mizu.comptime.u64 = 8\n"
		~ "byte : type = mizu.doir.type_base(%8, %8)\n"
		~ "handle : alias = byte\n"
		~ "_ : type = mizu.doir.type_union(handle)\n", mod, root));

	immutable byte_ = resolveLookupName(mod, internIn(mod, "byte"), root);
	immutable handle = resolveLookupName(mod, internIn(mod, "handle"), root);
	assert(flagsSet(mod, byte_, Flags.Union));
	assert(hasComponent!Alias(mod, handle)); // still a name for it, not a type
	diagnostics().clear();
}

unittest { // M-Unique is the exception: it edits the entity that was *named*
	Module mod;
	EntityId root;
	scope(exit) freeModule(mod);

	assert(compileWithMizu(
		"%8 : mizu.comptime.u64 = 8\n"
		~ "byte : type = mizu.doir.type_base(%8, %8)\n"
		~ "token : alias = byte\n"
		~ "_ : type = mizu.doir.type_make_unique(token)\n", mod, root));

	immutable byte_ = resolveLookupName(mod, internIn(mod, "byte"), root);
	immutable token = resolveLookupName(mod, internIn(mod, "token"), root);

	// Severed, same layout, its own discriminator - and `byte` untouched, which
	// is the whole point (following the alias would have inverted it).
	assert(!hasComponent!Alias(mod, token));
	assert(getComponent!TypeDefinition(mod, token).size == 8);
	assert(getComponent!TypeDefinition(mod, token).unique != 0);
	assert(getComponent!TypeDefinition(mod, byte_).unique == 0);
	diagnostics().clear();
}

unittest { // M-Ctor allocates: the call becomes the pointer type
	Module mod;
	EntityId root;
	scope(exit) freeModule(mod);

	assert(compileWithMizu(
		"%8 : mizu.comptime.u64 = 8\n"
		~ "%4 : mizu.comptime.u64 = 4\n"
		~ "byte : type = mizu.doir.type_base(%8, %8)\n"
		~ "bp : type = mizu.doir.type_pointer(byte)\n"
		~ "quad : type = mizu.doir.type_array(byte, %4)\n", mod, root));

	immutable byte_ = resolveLookupName(mod, internIn(mod, "byte"), root);
	immutable bp = resolveLookupName(mod, internIn(mod, "bp"), root);
	immutable quad = resolveLookupName(mod, internIn(mod, "quad"), root);

	assert(getComponent!Pointer(mod, bp).related[0] == byte_);
	assert(getComponent!Pointer(mod, bp).size == 0); // unbounded
	// An array is "a pointer that knows its length".
	assert(getComponent!Pointer(mod, quad).related[0] == byte_);
	assert(getComponent!Pointer(mod, quad).size == 4);
	diagnostics().clear();
}

unittest { // the queries fold to numbers the compiler can read back
	Module mod;
	EntityId root;
	scope(exit) freeModule(mod);

	assert(compileWithMizu(
		"%16 : mizu.comptime.u64 = 16\n"
		~ "%8 : mizu.comptime.u64 = 8\n"
		~ "word : type = mizu.doir.type_base(%16, %8)\n"
		~ "size : u64 = mizu.doir.type_size_bits(word)\n"
		~ "align : u64 = mizu.doir.type_align_bits(word)\n"
		~ "isty : u64 = mizu.doir.type_is(word)\n", mod, root));

	static real folded(ref Module mod, EntityId root, const(char)[] name) {
		immutable e = resolveLookupName(mod, internIn(mod, name), root);
		assert(e != invalidEntity);
		assert(hasComponent!ComptimeNumber(mod, e));
		return getComponent!ComptimeNumber(mod, e).value;
	}

	assert(folded(mod, root, "size") == 16);
	assert(folded(mod, root, "align") == 8);
	assert(folded(mod, root, "isty") == 1);
	diagnostics().clear();
}
