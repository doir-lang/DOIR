/// The IR API: the component types entities are built out of, block/function
/// builders and their block helpers, name resolution and source-location
/// recovery, entity copying, and the builtin global block. Ported from
/// interface.hpp plus interface.cpp, interface.resolve.cpp, interface.copy.cpp
/// and interface.global_block.cpp.
module doir.interface_;

static import fp.dynarray;
import fp.dynarray : daLength = length, daFree = free;
import fp.string : findSlices, splitSlices, strFree = free;

import diagnose.source_location : Detailed, SourceLocation;
import ecrs.relation : Relation, dynamicExtent;
import ecrs.storage : EntityId, EntityComponentIndices, invalidEntity;

import doir.diagnostics : invalidFileName, panic;
import doir.module_;
import doir.string_helpers : InternedString;

@nogc nothrow:


// ---------------------------------------------------------------------------
// Components
// ---------------------------------------------------------------------------
//
// Every component type the DOIR IR attaches to an entity, plus the `Lookup`
// tagged union that stands in for an unresolved reference. Ported from the
// component half of interface.hpp (and its `doir::lookup` namespace, which
// becomes the `Lookup*`-prefixed types here) - the same header the builders
// below came from.
//
// Components that wrap a relation get it through `mixin RelationBody`, which
// both gives them `related` and forwards the `swapEntities`/`finalize` hooks
// `ecrs.storage` looks for - `alias this` alone would forward them with the
// wrong `ref T` parameter type and silently opt the component out.

/// The entity `system.sorted`/`depth_first` and friends treat as "whatever
/// canonicalize::sort most recently produced".
enum EntityId currentCanonicalizeRoot = cast(EntityId)(-2);

/// The builtin names `verify.identifierStructure` refuses outside the
/// builtin block (the C++ `DOIR_BUILTIN_NAMES`).
static immutable string[3] builtinNames = ["type", "alias", "namespace"];


/// Gives a component a relation's `related` storage plus the two static
/// hooks `ecrs` looks for by name.
mixin template RelationBody(size_t N = dynamicExtent) {
	private alias RelationType = Relation!N;
	RelationType relation;
	alias relation this;

	static void swapEntities(ref typeof(this) self, ref EntityComponentIndices indices, EntityId a, EntityId b) @nogc nothrow {
		RelationType.swapEntities(self.relation, indices, a, b);
	}

	static if (N == dynamicExtent)
	static void finalize(ref typeof(this) self) @nogc nothrow {
		RelationType.finalize(self.relation);
	}
}


// ---------------------------------------------------------------------------
// Tags and simple payloads
// ---------------------------------------------------------------------------

/// Bit flags describing an entity. Mirrors `doir::flags`; note that the C++
/// original gives `Flatten` and `Tail` the same bit (1 << 11), which this
/// port preserves rather than quietly fixing.
struct Flags {
	enum : ushort {
		None = 0,
		Valueless = (1 << 1),
		Namespace = (1 << 2),

		Export = (1 << 3),
		Comptime = (1 << 4),
		AlwaysComptime = (1 << 5),
		NoComptime = (1 << 6), // Marks an object as never being comptime... currently unexposed
		Constant = (1 << 7),
		Union = (1 << 8),
		Pure = (1 << 9),
		Inline = (1 << 10),
		Flatten = (1 << 11),
		Tail = (1 << 11),
	}

	ushort flags = None;
}

/// An entity's source-level name.
struct Name {
	InternedString value;
}

/// A block of code. Alone (no `TypeOf` etc.) it represents a quoted block.
struct Block {
	mixin RelationBody!();
}

/// Back link from an entity to the block that lists it.
struct Parent {
	mixin RelationBody!1;
}

/// A function's return type. Also expects `FunctionInputs` and a
/// `Block`/`Valueless` attached.
struct FunctionReturnType {
	mixin RelationBody!1;
}

/// A function type's parameter types, or a call's arguments.
struct FunctionInputs {
	mixin RelationBody!();
}

/// The parameter names of a function type, as an fp dynarray.
struct FunctionParameterNames {
	InternedString* names = null;

	@nogc nothrow:

	static void finalize(ref FunctionParameterNames self) {
		if (self.names !is null) daFree(self.names);
	}

	size_t length() const @trusted { return daLength(cast(InternedString*) names); }
	inout(InternedString)[] slice() inout @trusted {
		return names is null ? null : (cast(inout(InternedString)*) names)[0 .. length()];
	}
	void push(InternedString v) @trusted { fp.dynarray.pushBack(names, v); }
	void assign(const(InternedString)[] src) @trusted {
		if (names !is null) { daFree(names); names = null; }
		foreach (v; src) fp.dynarray.pushBack(names, cast(InternedString) v);
	}
}

/// Marks an entity as parameter number `index` of the function it lives in.
struct FunctionParameter {
	size_t index;
}

/// A type. Also expects a `Block` attached (or `Pointer`, or function
/// inputs/return type for a function type).
struct TypeDefinition {
	size_t size, alignment;
	size_t unique = 0;
}

/// A pointer (or, with a non-zero `size`, an array) to `related[0]`.
struct Pointer {
	mixin RelationBody!1;
	size_t size = 0; // Size == 0 implies no bounds information
}

/// An alias to `related[0]`, optionally in another file.
struct Alias {
	mixin RelationBody!1;
	const(char)[] file = null; // Aliases can reference other files
	bool hasFile = false;
}

/// The type of a value. Expects a number, string, valueless, or block attached.
struct TypeOf {
	mixin RelationBody!1;
}

/// A numeric constant.
struct Number {
	real value; // TODO: should use bigint rational instead?
}

/// The compile-time-evaluated value of a `Number`-typed entity.
struct ComptimeNumber {
	real value;
}

/// A string constant.
struct DString {
	InternedString value;
}

/// The compile-time-evaluated value of a string-typed entity.
struct ComptimeString {
	InternedString value;
}

/// A call of `related[0]`. Also expects `FunctionInputs` attached.
struct Call {
	mixin RelationBody!1;
}

/// Attached to compile-time substitutions to record what call created them.
struct PrintAsCall {
	mixin RelationBody!1;
}


// ---------------------------------------------------------------------------
// Lookups (the C++ `doir::lookup` namespace)
// ---------------------------------------------------------------------------

/// Either a resolved entity or the name still waiting to be resolved to one.
/// The C++ version was a `std::variant<entity_t, interned_string>`; without
/// exceptions a plain tagged struct is both simpler and cheaper.
struct Lookup {
	private bool resolvedFlag = false;
	private EntityId entityValue = invalidEntity;
	private InternedString nameValue;

	@nogc nothrow:

	this(EntityId e) { resolvedFlag = true; entityValue = e; }
	this(InternedString n) { resolvedFlag = false; nameValue = n; }

	bool resolved() const { return resolvedFlag; }
	EntityId entity() const in(resolvedFlag) { return entityValue; }
	InternedString name() const in(!resolvedFlag) { return nameValue; }

	void opAssign(EntityId e) { resolvedFlag = true; entityValue = e; }
	void opAssign(InternedString n) { resolvedFlag = false; nameValue = n; }

	static void swapEntities(ref Lookup self, EntityId a, EntityId b) {
		if (!self.resolvedFlag) return;
		if (self.entityValue == a) self.entityValue = b;
		else if (self.entityValue == b) self.entityValue = a;
	}
}

/// Boilerplate shared by every single-`Lookup` component.
mixin template LookupBody() {
	Lookup lookup;
	alias lookup this;

	static void swapEntities(ref typeof(this) self, ref EntityComponentIndices indices, EntityId a, EntityId b) @nogc nothrow {
		Lookup.swapEntities(self.lookup, a, b);
	}
}

/// A bare unresolved reference.
struct LookupLookup {
	mixin LookupBody;
}

/// An unresolved function return type.
struct LookupFunctionReturnType {
	mixin LookupBody;
}

/// An unresolved alias target, optionally in another file.
struct LookupAlias {
	mixin LookupBody;
	const(char)[] file = null; // Aliases can reference other files
	bool hasFile = false;
}

/// An unresolved type.
struct LookupTypeOf {
	mixin LookupBody;
}

/// An unresolved call target.
struct LookupCall {
	mixin LookupBody;
}

/// A list of unresolved arguments/parameter types, as an fp dynarray.
struct LookupFunctionInputs {
	Lookup* lookups = null;

	@nogc nothrow:

	static void swapEntities(ref LookupFunctionInputs self, ref EntityComponentIndices indices, EntityId a, EntityId b) @trusted {
		foreach (i; 0 .. self.length)
			Lookup.swapEntities(self.lookups[i], a, b);
	}

	static void finalize(ref LookupFunctionInputs self) {
		if (self.lookups !is null) daFree(self.lookups);
	}

	size_t length() const @trusted { return daLength(cast(Lookup*) lookups); }
	inout(Lookup)[] slice() inout @trusted {
		return lookups is null ? null : (cast(inout(Lookup)*) lookups)[0 .. length()];
	}
	ref inout(Lookup) opIndex(size_t i) inout @trusted { return (cast(inout(Lookup)*) lookups)[i]; }
	void push(Lookup l) @trusted { fp.dynarray.pushBack(lookups, l); }
	void clear() @trusted { if (lookups !is null) { daFree(lookups); lookups = null; } }
}


// ---------------------------------------------------------------------------
// Backend components
// ---------------------------------------------------------------------------

/// The machine register the register allocator assigned to an entity
/// (the C++ `doir::opt::assigned_register`).
struct AssignedRegister {
	size_t reg;
}


// ---------------------------------------------------------------------------
// Owning lists (what the C++ returns by value as std::vector)
// ---------------------------------------------------------------------------

/// An owning list of `Lookup`s, standing in for the C++
/// `doir::lookup::function_inputs` values passed around by value. Free it
/// with `.free()` when done.
struct LookupList {
	Lookup* data = null;

	@nogc nothrow:

	void free() @trusted { if (data !is null) { fp.dynarray.free(data); data = null; } }
	size_t length() const @trusted { return daLength(cast(Lookup*) data); }
	ref inout(Lookup) opIndex(size_t i) inout @trusted { return (cast(inout(Lookup)*) data)[i]; }
	void push(Lookup l) @trusted { fp.dynarray.pushBack(data, l); }
	inout(Lookup)[] slice() inout @trusted {
		return data is null ? null : (cast(inout(Lookup)*) data)[0 .. length()];
	}
}

/// An owning list of entities.
struct EntityList {
	EntityId* data = null;

	@nogc nothrow:

	void free() @trusted { if (data !is null) { fp.dynarray.free(data); data = null; } }
	size_t length() const @trusted { return daLength(cast(EntityId*) data); }
	ref inout(EntityId) opIndex(size_t i) inout @trusted { return (cast(inout(EntityId)*) data)[i]; }
	void push(EntityId e) @trusted { fp.dynarray.pushBack(data, e); }
	inout(EntityId)[] slice() inout @trusted {
		return data is null ? null : (cast(inout(EntityId)*) data)[0 .. length()];
	}
}

/// Widens a resolved `FunctionInputs` into a list of `Lookup`s
/// (the C++ `lookup::function_inputs::to_lookup`).
LookupList toLookupList(ref Module mod, EntityId e) @trusted {
	LookupList out_;
	auto inputs = &getComponent!FunctionInputs(mod, e);
	foreach (i; 0 .. daLength(inputs.related))
		out_.push(Lookup(inputs.related[i]));
	return out_;
}

/// The inputs of `e`, whether they are resolved or not - the
/// `has_component<function_inputs> ? to_lookup(...) : get<lookup::function_inputs>`
/// idiom that appears all over the C++. The caller frees the result.
LookupList inputsOf(ref Module mod, EntityId e) @trusted {
	if (hasComponent!FunctionInputs(mod, e))
		return toLookupList(mod, e);

	LookupList out_;
	auto lookups = &getComponent!LookupFunctionInputs(mod, e);
	foreach (i; 0 .. lookups.length)
		out_.push((*lookups)[i]);
	return out_;
}

/// True if `e` carries either flavour of function inputs.
bool hasAnyInputs(ref Module mod, EntityId e) {
	return hasComponent!FunctionInputs(mod, e) || hasComponent!LookupFunctionInputs(mod, e);
}

/// The call target of `e`, resolved or not.
Lookup callOf(ref Module mod, EntityId e) {
	return hasComponent!Call(mod, e)
		? Lookup(getComponent!Call(mod, e).related[0])
		: getComponent!LookupCall(mod, e).lookup;
}

/// The type of `e`, resolved or not.
Lookup typeOfLookup(ref Module mod, EntityId e) {
	return hasComponent!TypeOf(mod, e)
		? Lookup(getComponent!TypeOf(mod, e).related[0])
		: getComponent!LookupTypeOf(mod, e).lookup;
}

/// The return type of `e`, resolved or not; `found` is false when it has
/// neither component.
Lookup returnTypeOf(ref Module mod, EntityId e, out bool found) {
	if (hasComponent!FunctionReturnType(mod, e)) {
		found = true;
		return Lookup(getComponent!FunctionReturnType(mod, e).related[0]);
	}
	if (hasComponent!LookupFunctionReturnType(mod, e)) {
		found = true;
		return getComponent!LookupFunctionReturnType(mod, e).lookup;
	}
	found = false;
	return Lookup.init;
}


// ---------------------------------------------------------------------------
// Block helpers
// ---------------------------------------------------------------------------

/// Index of `e` within `blockEntity`'s block, or `invalidEntity` when absent.
size_t blockOffsetOf(ref Module mod, EntityId blockEntity, EntityId e) @trusted {
	auto block = &getComponent!Block(mod, blockEntity);
	foreach (i; 0 .. daLength(block.related))
		if (block.related[i] == e) return i;
	return invalidEntity;
}

/// Splices `count` of `srcBlock`'s children into `destBlock` at `destOffset`,
/// reparenting each one.
void inlineInto(ref Module mod, EntityId srcBlock, EntityId destE, size_t destOffset = 0, size_t srcOffset = 0, size_t count = size_t.max) @trusted {
	if (!hasComponent!Block(mod, destE))
		panic("Cannot inline into a non-block entity");

	immutable srcLength = daLength(getComponent!Block(mod, srcBlock).related);
	if (count == size_t.max) count = srcLength - srcOffset;
	if (destOffset > daLength(getComponent!Block(mod, destE).related))
		panic("Cannot inline into a block at an offset greater than the block's size");
	if (srcOffset + count > srcLength)
		panic("Cannot inline from a block at an offset + count greater than the block's size");

	foreach (i; 0 .. count) {
		immutable child = getComponent!Block(mod, srcBlock).related[srcOffset + i];
		auto dest = &getComponent!Block(mod, destE);
		fp.dynarray.insert(dest.related, destOffset + i, child);
	}
	foreach (i; 0 .. count) {
		immutable child = getComponent!Block(mod, destE).related[destOffset + i];
		getOrAddComponent!Parent(mod, child).related[0] = destE;
	}
}

/// A freestanding block is one that is not attached to a type, function, or
/// alias - just a block of code that can be executed.
bool blockIsFreestanding(ref Module mod, EntityId blockEntity) {
	if (!hasComponent!Block(mod, blockEntity)) return false;
	if (!hasComponent!TypeOf(mod, blockEntity)) return false;

	immutable blockType = resolveCached(mod, "block", 1, true);
	if (getComponent!TypeOf(mod, blockEntity).related[0] != blockType) return false;

	return true;
}

/// Prefixes every name in `blockEntity`'s subtree with `prefix`.
void prependToNames(ref Module mod, EntityId blockEntity, const(char)[] prefix) @trusted {
	import fp.string : concatenateSlice, strFree = free, strSlice = slice;

	auto block = &getComponent!Block(mod, blockEntity);
	foreach (i; 0 .. daLength(block.related)) {
		immutable e = block.related[i];
		if (hasComponent!Name(mod, e)) {
			auto name = &getComponent!Name(mod, e);
			char* joined = null;
			concatenateSlice(joined, prefix);
			concatenateSlice(joined, name.value.view);
			name.value = internIn(mod, strSlice(joined));
			strFree(joined);
		}
		if (hasComponent!Block(mod, e))
			prependToNames(mod, e, prefix);
	}
}

/// For each input index, the entity in `blockEntity` declared as that
/// parameter. The caller frees the result.
EntityList associatedParameters(ref Module mod, size_t inputCount, EntityId blockEntity) @trusted {
	EntityList parameters;
	auto block = &getComponent!Block(mod, blockEntity);
	foreach (i; 0 .. inputCount)
		foreach (j; 0 .. daLength(block.related)) {
			immutable e = block.related[j];
			if (!hasComponent!FunctionParameter(mod, e)) continue;
			if (getComponent!FunctionParameter(mod, e).index == i) {
				parameters.push(e);
				break;
			}
		}
	return parameters;
}

/// Strips whatever value `root` carries, leaving the declaration behind.
void stripValue(ref Module mod, EntityId root, bool stripConstants = true, bool stripCalls = true, bool stripBlocks = true) {
	if (stripConstants && hasComponent!Number(mod, root)) {
		removeComponent!Number(mod, root);
		removeComponent!TypeOf(mod, root);
	}
	if (stripConstants && hasComponent!DString(mod, root)) {
		removeComponent!DString(mod, root);
		removeComponent!TypeOf(mod, root);
	}
	if (stripConstants && flagsSet(mod, root, Flags.Valueless)) {
		getComponent!Flags(mod, root).flags &= ~cast(ushort) Flags.Valueless;
		removeComponent!TypeOf(mod, root);
	}
	if (stripCalls && hasComponent!Call(mod, root)) {
		removeComponent!Call(mod, root);
		if (hasComponent!FunctionInputs(mod, root))
			removeComponent!FunctionInputs(mod, root);
		removeComponent!TypeOf(mod, root);
	}
	if (stripBlocks && hasComponent!Block(mod, root)) {
		removeComponent!Block(mod, root);
		removeComponent!TypeOf(mod, root);
	}
}


// ---------------------------------------------------------------------------
// Builders
// ---------------------------------------------------------------------------

/// Appends (or prepends) a fresh, named, parented entity to `blockEntity`.
EntityId pushCommon(ref Module mod, EntityId blockEntity, InternedString name, bool append = true) @trusted {
	assert(hasComponent!Block(mod, blockEntity));
	immutable out_ = addEntity(mod);
	if (name.view != "_")
		addComponent!Name(mod, out_).value = name;
	addComponent!Parent(mod, out_).related[0] = blockEntity;
	auto related = &getComponent!Block(mod, blockEntity).related;
	if (append) fp.dynarray.pushBack(*related, out_);
	else fp.dynarray.insert(*related, 0, out_);
	return out_;
}

/// Builds the contents of one block. A thin cursor over `(mod, block)`, as
/// in the C++.
struct BlockBuilder {
	EntityId block = 0;
	Module* mod = null;

	@nogc nothrow:

	/// Detaches the builder and hands back the block it was building.
	EntityId end() {
		mod = null;
		immutable out_ = block;
		block = invalidEntity;
		return out_;
	}

	ref BlockBuilder clear() @trusted {
		auto related = &getComponent!Block(*mod, block).related;
		fp.dynarray.clear(*related);
		return this;
	}
}

/// A `BlockBuilder` that also knows how to declare parameters.
struct FunctionBuilder {
	BlockBuilder builder;
	alias builder this;
}

/// Starts a new top-level block in `mod`.
BlockBuilder createBlockBuilder(ref Module mod) {
	BlockBuilder out_;
	out_.mod = &mod;
	out_.block = addEntity(mod);
	addComponent!Block(mod, out_.block);
	return out_;
}


// --- values -----------------------------------------------------------------

// %0 : i32 = 5
EntityId attachNumber(ref Module mod, EntityId to, EntityId type, real value) {
	addComponent!TypeOf(mod, to).related[0] = type;
	addComponent!Number(mod, to).value = value;
	getOrAddComponent!Flags(mod, to).flags |= Flags.Comptime;
	return to;
}
EntityId attachNumber(ref Module mod, EntityId to, InternedString typeLookup, real value) {
	addComponent!LookupTypeOf(mod, to).lookup = typeLookup;
	addComponent!Number(mod, to).value = value;
	getOrAddComponent!Flags(mod, to).flags |= Flags.Comptime;
	return to;
}
EntityId pushNumber(ref BlockBuilder b, InternedString name, EntityId type, real value) {
	return attachNumber(*b.mod, pushCommon(*b.mod, b.block, name), type, value);
}
EntityId pushNumber(ref BlockBuilder b, InternedString name, InternedString typeLookup, real value) {
	return attachNumber(*b.mod, pushCommon(*b.mod, b.block, name), typeLookup, value);
}

// %1 : u8p = "hello world"
EntityId attachString(ref Module mod, EntityId to, EntityId type, InternedString value) {
	addComponent!TypeOf(mod, to).related[0] = type;
	addComponent!DString(mod, to).value = value;
	getOrAddComponent!Flags(mod, to).flags |= Flags.Comptime;
	return to;
}
EntityId attachString(ref Module mod, EntityId to, InternedString typeLookup, InternedString value) {
	addComponent!LookupTypeOf(mod, to).lookup = typeLookup;
	addComponent!DString(mod, to).value = value;
	getOrAddComponent!Flags(mod, to).flags |= Flags.Comptime;
	return to;
}
EntityId pushString(ref BlockBuilder b, InternedString name, EntityId type, InternedString value) {
	return attachString(*b.mod, pushCommon(*b.mod, b.block, name), type, value);
}
EntityId pushString(ref BlockBuilder b, InternedString name, InternedString typeLookup, InternedString value) {
	return attachString(*b.mod, pushCommon(*b.mod, b.block, name), typeLookup, value);
}

// %2 : i32
EntityId attachValueless(ref Module mod, EntityId to, EntityId type) {
	addComponent!TypeOf(mod, to).related[0] = type;
	addComponent!Flags(mod, to).flags = Flags.Valueless;
	return to;
}
EntityId attachValueless(ref Module mod, EntityId to, InternedString typeLookup) {
	addComponent!LookupTypeOf(mod, to).lookup = typeLookup;
	addComponent!Flags(mod, to).flags = Flags.Valueless;
	return to;
}
EntityId pushValueless(ref BlockBuilder b, InternedString name, EntityId type) {
	return attachValueless(*b.mod, pushCommon(*b.mod, b.block, name), type);
}
EntityId pushValueless(ref BlockBuilder b, InternedString name, InternedString typeLookup) {
	return attachValueless(*b.mod, pushCommon(*b.mod, b.block, name), typeLookup);
}


// --- calls ------------------------------------------------------------------

private void attachTypeSlot(ref Module mod, EntityId to, EntityId type) {
	addComponent!TypeOf(mod, to).related[0] = type;
}
private void attachTypeSlot(ref Module mod, EntityId to, InternedString type) {
	addComponent!LookupTypeOf(mod, to).lookup = type;
}

private void attachInputs(ref Module mod, EntityId to, const(EntityId)[] arguments) @trusted {
	auto inputs = &addComponent!FunctionInputs(mod, to);
	foreach (a; arguments) fp.dynarray.pushBack(inputs.related, a);
}
private void attachInputs(ref Module mod, EntityId to, const(Lookup)[] arguments) @trusted {
	auto inputs = &addComponent!LookupFunctionInputs(mod, to);
	foreach (a; arguments) inputs.push(cast(Lookup) a);
}

private void attachCallee(ref Module mod, EntityId to, EntityId function_) {
	addComponent!Call(mod, to).related[0] = function_;
}
private void attachCallee(ref Module mod, EntityId to, InternedString functionLookup) {
	addComponent!LookupCall(mod, to).lookup = functionLookup;
}

/// `%4 : i32 = add(%0, %2)`, in every combination of resolved/unresolved
/// type, callee and arguments the C++ overload set covers.
EntityId attachCall(TType, TFunc, TArg)(ref Module mod, EntityId to, TType type, TFunc function_, const(TArg)[] arguments) {
	attachTypeSlot(mod, to, type);
	attachInputs(mod, to, arguments);
	attachCallee(mod, to, function_);
	return to;
}

/// Ditto, pushing a new entity into the builder's block first.
EntityId pushCall(TType, TFunc, TArg)(ref BlockBuilder b, InternedString name, TType type, TFunc function_, const(TArg)[] arguments) {
	return attachCall(*b.mod, pushCommon(*b.mod, b.block, name), type, function_, arguments);
}


// --- sub-blocks -------------------------------------------------------------

// %5 : i32 = { built block... }
BlockBuilder attachSubblock(ref Module mod, EntityId to, EntityId type) {
	addComponent!TypeOf(mod, to).related[0] = type;
	addComponent!Block(mod, to);
	return BlockBuilder(to, &mod);
}
BlockBuilder attachSubblock(ref Module mod, EntityId to, InternedString typeLookup) {
	addComponent!LookupTypeOf(mod, to).lookup = typeLookup;
	addComponent!Block(mod, to);
	return BlockBuilder(to, &mod);
}
BlockBuilder pushSubblock(ref BlockBuilder b, InternedString name, EntityId type) {
	return attachSubblock(*b.mod, pushCommon(*b.mod, b.block, name), type);
}
BlockBuilder pushSubblock(ref BlockBuilder b, InternedString name, InternedString typeLookup) {
	return attachSubblock(*b.mod, pushCommon(*b.mod, b.block, name), typeLookup);
}


// --- functions --------------------------------------------------------------

/// `add : (a: i32, b: i32 = 5) i32 = { built block... }`
FunctionBuilder attachFunction(ref Module mod, EntityId to, EntityId functionType, bool pushParameters = false) @trusted {
	import core.stdc.stdio : snprintf;
	import fp.string : strSlice = slice;

	addComponent!TypeOf(mod, to).related[0] = functionType;
	addComponent!Block(mod, to);
	if (hasComponent!FunctionReturnType(mod, functionType))
		addComponent!FunctionReturnType(mod, to).related[0] = getComponent!FunctionReturnType(mod, functionType).related[0];
	else
		addComponent!LookupFunctionReturnType(mod, to).lookup = getComponent!LookupFunctionReturnType(mod, functionType).lookup;

	FunctionBuilder out_;
	out_.builder = BlockBuilder(to, &mod);
	if (!pushParameters) return out_;

	auto inputs = inputsOf(mod, functionType);
	scope(exit) inputs.free();

	foreach (i; 0 .. inputs.length) {
		InternedString name;
		if (hasComponent!FunctionParameterNames(mod, functionType))
			name = getComponent!FunctionParameterNames(mod, functionType).slice[i];
		else {
			char[24] buffer;
			immutable n = snprintf(buffer.ptr, buffer.length, "a%zu", i);
			name = internIn(mod, buffer[0 .. n]);
		}

		if (inputs[i].resolved())
			pushValuelessParameter(out_, i, name, inputs[i].entity());
		else
			pushValuelessParameter(out_, i, name, inputs[i].name());
	}
	return out_;
}
FunctionBuilder pushFunction(ref BlockBuilder b, InternedString name, EntityId functionType, bool pushParameters = false) {
	return attachFunction(*b.mod, pushCommon(*b.mod, b.block, name), functionType, pushParameters);
}

/// `foo : () void`
EntityId attachValuelessFunction(ref Module mod, EntityId to, EntityId functionType) {
	addComponent!TypeOf(mod, to).related[0] = functionType;
	if (hasComponent!FunctionReturnType(mod, functionType))
		addComponent!FunctionReturnType(mod, to).related[0] = getComponent!FunctionReturnType(mod, functionType).related[0];
	else
		addComponent!LookupFunctionReturnType(mod, to).lookup = getComponent!LookupFunctionReturnType(mod, functionType).lookup;
	return to;
}
EntityId pushValuelessFunction(ref BlockBuilder b, InternedString name, EntityId functionType) {
	return attachValuelessFunction(*b.mod, pushCommon(*b.mod, b.block, name), functionType);
}


// --- types ------------------------------------------------------------------

/// `vec3 : type = { x : f32; y : f32; z : f32; }`
BlockBuilder attachType(ref Module mod, EntityId to) {
	addComponent!TypeDefinition(mod, to);
	addComponent!Block(mod, to);
	return BlockBuilder(to, &mod);
}
BlockBuilder pushType(ref BlockBuilder b, InternedString name) {
	return attachType(*b.mod, pushCommon(*b.mod, b.block, name));
}

/// Widens an entity id or a name into a `Lookup`.
Lookup toLookup(T)(T v) {
	static if (is(T == Lookup)) return v;
	else return Lookup(v);
}

/// `func_t : type = (a: i32) -> f32`
///
/// Which flavour of return-type component gets attached follows the
/// *parameter* flavour, exactly as the C++ overload pair does: a `Lookup`
/// parameter list always pairs with `LookupFunctionReturnType`, even when the
/// return type handed in is an already-resolved entity.
EntityId attachFunctionType(TParam, TReturn)(ref Module mod, EntityId to, const(TParam)[] parameterTypes,
	TReturn returnType, bool hasReturnType, const(InternedString)[] parameterNames = null) @trusted
{
	addComponent!TypeDefinition(mod, to);
	attachInputs(mod, to, parameterTypes);

	static if (is(TParam == EntityId)) {
		static assert(is(TReturn == EntityId),
			"a resolved parameter list needs a resolved return type");
		if (hasReturnType) addComponent!FunctionReturnType(mod, to).related[0] = returnType;
	} else {
		if (hasReturnType) addComponent!LookupFunctionReturnType(mod, to).lookup = toLookup(returnType);
	}

	if (parameterNames.length) {
		assert(parameterNames.length == parameterTypes.length);
		addComponent!FunctionParameterNames(mod, to).assign(parameterNames);
	}
	return to;
}
EntityId pushFunctionType(TParam, TReturn)(ref BlockBuilder b, InternedString name, const(TParam)[] parameterTypes,
	TReturn returnType, bool hasReturnType, const(InternedString)[] parameterNames = null)
{
	return attachFunctionType(*b.mod, pushCommon(*b.mod, b.block, name), parameterTypes, returnType, hasReturnType, parameterNames);
}

/// `bp : type = type.pointer(byte)`
EntityId attachPointer(ref Module mod, EntityId to, EntityId base, size_t size = 0) {
	addComponent!TypeDefinition(mod, to);
	auto p = &addComponent!Pointer(mod, to);
	p.related[0] = base;
	p.size = size;
	getOrAddComponent!Flags(mod, to).flags |= Flags.Comptime;
	return to;
}
EntityId pushPointer(ref BlockBuilder b, InternedString name, EntityId base, size_t size = 0) {
	return attachPointer(*b.mod, pushCommon(*b.mod, b.block, name), base, size);
}


// --- aliases and namespaces -------------------------------------------------

/// `color : alias = vec3`
EntityId attachAlias(ref Module mod, EntityId to, EntityId refE) {
	addComponent!Alias(mod, to).related[0] = refE;
	return to;
}
EntityId attachAlias(ref Module mod, EntityId to, InternedString refLookup) {
	addComponent!LookupAlias(mod, to).lookup = refLookup;
	return to;
}
EntityId pushAlias(ref BlockBuilder b, InternedString name, EntityId refE) {
	return attachAlias(*b.mod, pushCommon(*b.mod, b.block, name), refE);
}
EntityId pushAlias(ref BlockBuilder b, InternedString name, InternedString refLookup) {
	return attachAlias(*b.mod, pushCommon(*b.mod, b.block, name), refLookup);
}

/// `math : namespace = { built block... }`
BlockBuilder attachNamespace(ref Module mod, EntityId to) {
	addComponent!Flags(mod, to).flags = Flags.Namespace;
	addComponent!Block(mod, to);
	return BlockBuilder(to, &mod);
}
BlockBuilder pushNamespace(ref BlockBuilder b, InternedString name) {
	return attachNamespace(*b.mod, pushCommon(*b.mod, b.block, name));
}


// --- parameters -------------------------------------------------------------

/// Declares every parameter of `functionType` inside the function being built.
void pushParameters(ref FunctionBuilder fb, EntityId functionType, const(InternedString)[] parameterNames = null) @trusted {
	import core.stdc.stdio : snprintf;

	auto mod = fb.mod;
	if (!hasAnyInputs(*mod, functionType)) return;

	auto inputs = inputsOf(*mod, functionType);
	scope(exit) inputs.free();

	InternedString[] names;
	InternedString* generated = null;
	scope(exit) if (generated !is null) fp.dynarray.free(generated);

	if (parameterNames.length)
		names = cast(InternedString[]) parameterNames;
	else if (hasComponent!FunctionParameterNames(*mod, functionType))
		names = cast(InternedString[]) getComponent!FunctionParameterNames(*mod, functionType).slice;
	else {
		foreach (i; 0 .. inputs.length) {
			char[24] buffer;
			immutable n = snprintf(buffer.ptr, buffer.length, "a%zu", i);
			fp.dynarray.pushBack(generated, internIn(*mod, buffer[0 .. n]));
		}
		names = generated[0 .. inputs.length];
	}

	// Walked backwards because each parameter is *prepended*, which leaves
	// them in declaration order once the loop finishes.
	for (size_t i = inputs.length; i-- > 0;) {
		if (inputs[i].resolved())
			pushValuelessParameter(fb, i, names[i], inputs[i].entity(), false);
		else
			pushValuelessParameter(fb, i, names[i], inputs[i].name(), false);
	}
}

// (a : i32 = 5)
EntityId attachNumberParameter(TType)(ref Module mod, EntityId to, size_t index, TType type, real value) {
	addComponent!FunctionParameter(mod, to).index = index;
	return attachNumber(mod, to, type, value);
}
EntityId pushNumberParameter(TType)(ref FunctionBuilder fb, size_t index, InternedString name, TType type, real value, bool append = true) {
	return attachNumberParameter(*fb.mod, pushCommon(*fb.mod, fb.block, name, append), index, type, value);
}

// (b : u8p = "hello")
EntityId attachStringParameter(TType)(ref Module mod, EntityId to, size_t index, TType type, InternedString value) {
	addComponent!FunctionParameter(mod, to).index = index;
	return attachString(mod, to, type, value);
}
EntityId pushStringParameter(TType)(ref FunctionBuilder fb, size_t index, InternedString name, TType type, InternedString value, bool append = true) {
	return attachStringParameter(*fb.mod, pushCommon(*fb.mod, fb.block, name, append), index, type, value);
}

// (c : i32)
EntityId attachValuelessParameter(TType)(ref Module mod, EntityId to, size_t index, TType type) {
	addComponent!FunctionParameter(mod, to).index = index;
	return attachValueless(mod, to, type);
}
EntityId pushValuelessParameter(TType)(ref FunctionBuilder fb, size_t index, InternedString name, TType type, bool append = true) {
	return attachValuelessParameter(*fb.mod, pushCommon(*fb.mod, fb.block, name, append), index, type);
}


// ===========================================================================
// Name resolution, scope walking and source locations (interface.resolve.cpp)
// ===========================================================================

// ---------------------------------------------------------------------------
// Source locations
// ---------------------------------------------------------------------------

/// The byte range `subtree` came from, recovered from whichever of the two
/// location components it carries - or, failing that, by finding its name in
/// the module's source text.
SourceLocation findSourceLocation(ref Module mod, EntityId subtree) @trusted {
	if (hasComponent!Detailed(mod, subtree))
		return getComponent!Detailed(mod, subtree).toBytes(mod.source);

	if (hasComponent!SourceLocation(mod, subtree))
		return getComponent!SourceLocation(mod, subtree);

	if (hasComponent!Name(mod, subtree)) {
		auto name = getComponent!Name(mod, subtree).value;
		immutable start = findSlices(mod.source, name.view, 0);
		if (start == size_t.max)
			panic("Failed to generate source location for entity");
		return SourceLocation(workingFileOr(mod, invalidFileName), start, start + name.length);
	}

	panic("Failed to generate source location for entity");
}

/// Ditto, as line/column pairs.
Detailed findDetailedSourceLocation(ref Module mod, EntityId subtree) {
	// Short-circuits the expensive detailed -> byte conversion in the other
	// function when the detailed location is already on hand.
	if (hasComponent!Detailed(mod, subtree))
		return getComponent!Detailed(mod, subtree);

	return findSourceLocation(mod, subtree).toDetailed(mod.source);
}


// ---------------------------------------------------------------------------
// Scope walking
// ---------------------------------------------------------------------------

/// Finds the nearest entity at or after `e` that carries a `Block` (and, when
/// `mustContain` is given, whose block lists it).
///
/// The C++ version was written recursively with a "how terrible of an idea is
/// this?" note attached; the loop here has the same semantics without the
/// stack depth.
EntityId findBlock(ref Module mod, EntityId e, EntityId mustContain = invalidEntity) @trusted {
	for (;;) {
		if (hasComponent!Block(mod, e)) {
			auto block = &getComponent!Block(mod, e);
			if (mustContain == invalidEntity) return e;
			foreach (i; 0 .. daLength(block.related))
				if (block.related[i] == mustContain) return e;
		}
		if (e > entityCount(mod)) return invalidEntity;
		++e;
	}
}

/// The block `e` belongs to. Prefer this to `findBlock`: it uses the cached
/// `Parent` component when there is one.
EntityId findParent(ref Module mod, EntityId e) {
	if (hasComponent!Parent(mod, e))
		return findBlock(mod, getComponent!Parent(mod, e).related[0]);
	return findBlock(mod, e, e);
}

/// The function `subtree` sits inside, or `invalidEntity` when it is not in
/// one.
EntityId findFunctionInsideOf(ref Module mod, EntityId subtree) {
	EntityId last = invalidEntity;
	while (subtree != invalidEntity && subtree != last) {
		if (hasComponent!FunctionReturnType(mod, subtree))
			return subtree;
		if (hasComponent!TypeOf(mod, subtree)) {
			immutable type = getComponent!TypeOf(mod, subtree).related[0];
			if (hasComponent!FunctionReturnType(mod, resolveTypeModifications(mod, type)))
				return subtree;
		}
		last = subtree;
		subtree = findParent(mod, last);
	}
	return invalidEntity;
}

private EntityId findNamespace(ref Module mod, EntityId blockEntity, const(char)[] name) @trusted {
	auto block = &getComponent!Block(mod, blockEntity);
	foreach (i; 0 .. daLength(block.related)) {
		immutable e = block.related[i];
		if (!hasComponent!Name(mod, e)) continue;
		if (getComponent!Name(mod, e).value.view != name) continue;
		// An alias to a namespace should be usable as a namespace segment
		// too (e.g. `ns2 : alias = ns` then `ns2.member`); resolve through
		// it (a no-op if `e` isn't itself an alias) before checking - and
		// return the *resolved* entity, since the caller looks up a `Block`
		// component on whatever we return, which an `Alias` entity doesn't
		// have.
		immutable resolved = resolveAlias(mod, e);
		if (flagsSet(mod, resolved, Flags.Namespace))
			return resolved;
	}
	return invalidEntity;
}

private EntityId findNameInBlock(ref Module mod, EntityId blockEntity, const(char)[] name) @trusted {
	auto block = &getComponent!Block(mod, blockEntity);
	foreach (i; 0 .. daLength(block.related)) {
		immutable e = block.related[i];
		if (!hasComponent!Name(mod, e)) continue;
		if (getComponent!Name(mod, e).value.view == name) return e;
	}
	return invalidEntity;
}

/// Resolves the dotted path `lookup` starting from `searchStart`'s scope.
/// With `strict`, the search starts in the block that actually contains
/// `searchStart` rather than the nearest block at or after it.
EntityId resolveLookupName(ref Module mod, InternedString lookup, EntityId searchStart, bool strict = false) @trusted {
	auto blockEntity = findBlock(mod, searchStart, strict ? searchStart : invalidEntity);
	if (blockEntity == invalidEntity) return blockEntity;

	auto namespaces = splitSlices(lookup.view, ".");
	scope(exit) fp.dynarray.free(namespaces);
	immutable count = daLength(namespaces);
	assert(count > 0);

	auto name = namespaces[count - 1];
	immutable segmentCount = count - 1; // everything before the final name

	if (segmentCount > 0) {
		EntityId namespaceEntity = blockEntity;
		do {
			namespaceEntity = findNamespace(mod, blockEntity, namespaces[0]);

			if (namespaceEntity == invalidEntity) {
				if (hasComponent!Parent(mod, blockEntity))
					blockEntity = findBlock(mod, getComponent!Parent(mod, blockEntity).related[0]);
				// `blockEntity` has no parent, so it is the outermost root - there is
				// no further enclosing scope to search. (Previously this fell through
				// to findBlock(mod, blockEntity + 1), which searches *forward* for the
				// next block-bearing entity - typically one of the root's own children
				// - causing the search to re-descend into the tree instead of
				// terminating, which could loop between the root and one of its
				// children forever for a namespace segment that doesn't exist
				// anywhere in scope.)
				else blockEntity = invalidEntity;

				if (blockEntity == invalidEntity)
					return invalidEntity;
			}
		} while (namespaceEntity == invalidEntity);

		foreach (i; 1 .. segmentCount) {
			namespaceEntity = findNamespace(mod, namespaceEntity, namespaces[i]);
			if (namespaceEntity == invalidEntity) return invalidEntity;
		}

		return findNameInBlock(mod, namespaceEntity, name);
	}

	while (blockEntity < entityCount(mod) && blockEntity != invalidEntity) {
		immutable res = findNameInBlock(mod, blockEntity, name);
		if (res != invalidEntity) return res;

		if (hasComponent!Parent(mod, blockEntity))
			blockEntity = findBlock(mod, getComponent!Parent(mod, blockEntity).related[0]);
		// See the matching comment above: no parent means `blockEntity` is the
		// outermost root, so the search is exhausted.
		else blockEntity = invalidEntity;
	}

	return invalidEntity;
}

/// Resolves `lookup` in place, writing the entity back into it on success.
EntityId resolveLookup(ref Module mod, ref Lookup lookup, EntityId searchStart, bool strict = false) {
	if (lookup.resolved()) return lookup.entity();

	immutable out_ = resolveLookupName(mod, lookup.name(), searchStart, strict);
	if (out_ == invalidEntity) return invalidEntity;

	lookup = out_;
	return out_;
}


// ---------------------------------------------------------------------------
// Type / alias resolution
// ---------------------------------------------------------------------------

/// The set of calls that merely decorate a type (`compiler.pointer` and the
/// two `always_*` markers), which `resolveTypeModifications` looks through.
EntityId[3] typeModifiers(ref Module mod, EntityId root) {
	return [
		resolveCached(mod, "compiler.pointer", root),
		resolveCached(mod, "compiler.always_inline", root),
		resolveCached(mod, "compiler.always_comptime", root),
	];
}

private bool isTypeModifier(ref Module mod, EntityId root, EntityId func) {
	auto modifiers = typeModifiers(mod, root);
	foreach (m; modifiers) if (m == func) return true;
	return false;
}

/// Peels `compiler.pointer(...)`-style decorations off a type until it
/// reaches the underlying definition, then resolves any alias on it.
EntityId resolveTypeModifications(ref Module mod, EntityId type) @trusted {
	while (hasComponent!Call(mod, type) || hasComponent!LookupCall(mod, type)) {
		Lookup call = hasComponent!Call(mod, type)
			? Lookup(getComponent!Call(mod, type).related[0])
			: getComponent!LookupCall(mod, type).lookup;
		if (!call.resolved()) return type;

		immutable func = call.entity();
		// If this is a type modifier then we keep resolving
		if (!isTypeModifier(mod, type, func))
			return type;

		if (hasComponent!FunctionInputs(mod, type)) {
			auto inputs = &getComponent!FunctionInputs(mod, type);
			if (daLength(inputs.related) == 0) return type;
			type = inputs.related[0];
		} else {
			auto inputs = &getComponent!LookupFunctionInputs(mod, type);
			if (inputs.length == 0 || !(*inputs)[0].resolved()) return type;
			type = (*inputs)[0].entity();
		}
	}
	return resolveAlias(mod, type);
}

/// The type at the bottom of a chain of pointers/aliases (the C++
/// `type_definition::base_type`).
EntityId baseType(ref Module mod, EntityId e) {
	e = resolveAlias(mod, e);

	if (hasComponent!Pointer(mod, e))
		return baseType(mod, getComponent!Pointer(mod, e).related[0]);

	return resolveAlias(mod, e);
}

/// Follows `alias` chains (resolved or not) up to `maxDepth` links.
EntityId resolveAlias(ref Module mod, EntityId aliasEntity, size_t maxDepth = 128) {
	foreach (depth; 0 .. maxDepth) {
		if (hasComponent!Alias(mod, aliasEntity)) {
			aliasEntity = getComponent!Alias(mod, aliasEntity).related[0];
			continue;
		} else if (hasComponent!LookupAlias(mod, aliasEntity)) {
			auto lookup = &getComponent!LookupAlias(mod, aliasEntity);
			if (lookup.lookup.resolved()) {
				aliasEntity = lookup.lookup.entity();
				continue;
			}
			// Still just a name (this entity's own alias hasn't been visited by
			// resolveLookups yet this pass) - resolve it right now rather than
			// giving up. Doesn't write the result back into `lookup`: that's
			// resolveLookups' job.
			immutable resolved = resolveLookupName(mod, lookup.lookup.name(), aliasEntity, true);
			if (resolved == invalidEntity || resolved == aliasEntity) return aliasEntity;
			aliasEntity = resolved;
			continue;
		}
		return aliasEntity;
	}
	return aliasEntity;
}

/// Resolves every alias in `aliases` in place.
void resolveAliases(ref Module mod, EntityId[] aliases, size_t maxDepth = 128) {
	foreach (ref a; aliases)
		a = resolveAlias(mod, a, maxDepth);
}


// ===========================================================================
// Copying entities and merging blocks (interface.copy.cpp)
// ===========================================================================

private EntityId applySub(EntityMap* subs, EntityId e) {
	return subs is null ? e : subs.get(e);
}

/// Copies a fixed-arity relation, substituting each slot.
private void copyFixedRelation(T)(ref Module mod, EntityId to, EntityId from, EntityMap* subs) {
	auto source = getComponent!T(mod, from);
	auto destination = &addComponent!T(mod, to);
	destination.related = source.related; // fixed-size array: a value copy
	static if (__traits(hasMember, T, "size")) destination.size = source.size;
	static if (__traits(hasMember, T, "file")) {
		destination.file = source.file;
		destination.hasFile = source.hasFile;
	}
	if (subs !is null)
		foreach (ref e; destination.related)
			e = subs.get(e);
}

/// Copies a dynamic relation, cloning its storage and substituting each slot.
private void copyDynamicRelation(T)(ref Module mod, EntityId to, EntityId from, EntityMap* subs) @trusted {
	immutable count = daLength(getComponent!T(mod, from).related);
	auto destination = &addComponent!T(mod, to);
	foreach (i; 0 .. count) {
		immutable e = getComponent!T(mod, from).related[i];
		fp.dynarray.pushBack(destination.related, e);
	}
	if (subs !is null) {
		auto dest = &getComponent!T(mod, to);
		foreach (i; 0 .. daLength(dest.related))
			dest.related[i] = subs.get(dest.related[i]);
	}
}

/// Copies a single-`Lookup` component. Note the `if (subs)` guard: the C++
/// only assigns the destination when a substitution table was supplied, and
/// this port keeps that (surprising) behaviour rather than changing what
/// callers passing `null` observe.
private void copyLookup(T)(ref Module mod, EntityId to, EntityId from, EntityMap* subs) {
	auto lookup = getComponent!T(mod, from);
	auto destination = &addComponent!T(mod, to);
	if (subs !is null) {
		if (lookup.lookup.resolved() && subs.contains(lookup.lookup.entity()))
			destination.lookup = subs.get(lookup.lookup.entity());
		else
			destination.lookup = lookup.lookup;
		static if (__traits(hasMember, T, "file")) {
			destination.file = lookup.file;
			destination.hasFile = lookup.hasFile;
		}
	}
}

private void copyLookupInputs(ref Module mod, EntityId to, EntityId from, EntityMap* subs) @trusted {
	auto source = inputsOf(mod, from);
	scope(exit) source.free();

	auto destination = &addComponent!LookupFunctionInputs(mod, to);
	if (subs is null) return; // see copyLookup's note
	foreach (i; 0 .. source.length) {
		auto l = source[i];
		if (l.resolved() && subs.contains(l.entity()))
			destination.push(Lookup(subs.get(l.entity())));
		else
			destination.push(l);
	}
}

private void copyParameterNames(ref Module mod, EntityId to, EntityId from) @trusted {
	auto source = getComponent!FunctionParameterNames(mod, from).slice;
	addComponent!FunctionParameterNames(mod, to).assign(source);
}

/// Copies every component that makes up `subtree`'s declaration onto `out_`,
/// rewriting entity references through `substitutions` when given.
void copyComponents(ref Module mod, EntityId out_, EntityId subtree, bool copyBlock = true, EntityMap* substitutions = null) @trusted {
	if (hasComponent!Name(mod, subtree))
		getOrAddComponent!Name(mod, out_) = getComponent!Name(mod, subtree);

	if (hasComponent!Flags(mod, subtree))
		getOrAddComponent!Flags(mod, out_) = getComponent!Flags(mod, subtree);

	if (hasComponent!TypeOf(mod, subtree) || hasComponent!LookupTypeOf(mod, subtree)) {
		// Type == back link
		if (hasComponent!TypeOf(mod, subtree))
			copyFixedRelation!TypeOf(mod, out_, subtree, substitutions);
		if (hasComponent!LookupTypeOf(mod, subtree))
			copyLookup!LookupTypeOf(mod, out_, subtree, substitutions);

		if (hasComponent!FunctionParameter(mod, subtree))
			addComponent!FunctionParameter(mod, out_) = getComponent!FunctionParameter(mod, subtree);

		immutable valueless = flagsSet(mod, subtree, Flags.Valueless);
		immutable number = hasComponent!Number(mod, subtree);
		immutable string_ = hasComponent!DString(mod, subtree);
		immutable call = hasComponent!Call(mod, subtree);
		immutable callLookup = hasComponent!LookupCall(mod, subtree);
		immutable functionDef = hasComponent!FunctionReturnType(mod, subtree);
		immutable functionDefLookup = hasComponent!LookupFunctionReturnType(mod, subtree);

		if (valueless) {
			// The flags copy above already carried `Valueless` across.
		} else if (number) {
			addComponent!Number(mod, out_) = getComponent!Number(mod, subtree);
		} else if (string_) {
			addComponent!DString(mod, out_) = getComponent!DString(mod, subtree);
		} else if (call || callLookup) {
			// Call == backlink
			if (hasComponent!Call(mod, subtree))
				copyFixedRelation!Call(mod, out_, subtree, substitutions);
			if (hasComponent!LookupCall(mod, subtree))
				copyLookup!LookupCall(mod, out_, subtree, substitutions);

			// inputs == backlink
			if (hasComponent!FunctionInputs(mod, subtree))
				copyDynamicRelation!FunctionInputs(mod, out_, subtree, substitutions);
			if (hasComponent!LookupFunctionInputs(mod, subtree))
				copyLookupInputs(mod, out_, subtree, substitutions);

			if (hasComponent!FunctionParameterNames(mod, subtree))
				copyParameterNames(mod, out_, subtree);

		} else if (functionDef || functionDefLookup) {
			// inputs == backlink
			if (hasComponent!FunctionInputs(mod, subtree))
				copyDynamicRelation!FunctionInputs(mod, out_, subtree, substitutions);
			// NOTE: the C++ guards this branch on `lookup::type_of` rather than
			// on `lookup::function_inputs`; kept as-is so a function definition
			// copies exactly the components it did before.
			if (hasComponent!LookupTypeOf(mod, subtree))
				copyLookupInputs(mod, out_, subtree, substitutions);

			if (hasComponent!FunctionParameterNames(mod, subtree))
				copyParameterNames(mod, out_, subtree);

			// return_type == backlink
			if (hasComponent!FunctionReturnType(mod, subtree))
				copyFixedRelation!FunctionReturnType(mod, out_, subtree, substitutions);
			if (hasComponent!LookupFunctionReturnType(mod, subtree))
				copyLookup!LookupFunctionReturnType(mod, out_, subtree, substitutions);
		}

	} else if (hasComponent!TypeDefinition(mod, subtree)) {
		addComponent!TypeDefinition(mod, out_) = getComponent!TypeDefinition(mod, subtree);

		if (hasAnyInputs(mod, subtree)) {
			// inputs == backlink
			if (hasComponent!FunctionInputs(mod, subtree))
				copyDynamicRelation!FunctionInputs(mod, out_, subtree, substitutions);
			if (hasComponent!LookupFunctionInputs(mod, subtree))
				copyLookupInputs(mod, out_, subtree, substitutions);

			// return_type == backlink
			if (hasComponent!FunctionReturnType(mod, subtree))
				copyFixedRelation!FunctionReturnType(mod, out_, subtree, substitutions);
			if (hasComponent!LookupFunctionReturnType(mod, subtree))
				copyLookup!LookupFunctionReturnType(mod, out_, subtree, substitutions);

		} else if (hasComponent!Pointer(mod, subtree)) {
			copyFixedRelation!Pointer(mod, out_, subtree, substitutions);
		}

	} else if (flagsSet(mod, subtree, Flags.Namespace)) {
		// The flags copy above already carried `Namespace` across.
	} else if (hasComponent!Alias(mod, subtree) || hasComponent!LookupAlias(mod, subtree)) {
		// alias == backlink
		if (hasComponent!Alias(mod, subtree))
			copyFixedRelation!Alias(mod, out_, subtree, substitutions);
		if (hasComponent!LookupAlias(mod, subtree))
			copyLookup!LookupAlias(mod, out_, subtree, substitutions);
	}

	if (copyBlock && hasComponent!Block(mod, subtree))
		copyDynamicRelation!Block(mod, out_, subtree, substitutions);
}


// ---------------------------------------------------------------------------
// Deep copy
// ---------------------------------------------------------------------------

alias ExtraCopyInstructions = void function(EntityId dest, EntityId src) @nogc nothrow;

private void deepCopyCopyComponents(ref Module mod, EntityId out_, EntityId blockEntity,
	ref EntityMap substitutions, ref EntityMap reverseSubstitutions, ExtraCopyInstructions extra) @trusted
{
	immutable subtree = reverseSubstitutions.get(out_);

	getOrAddComponent!Parent(mod, out_).related[0] = blockEntity;

	copyComponents(mod, out_, subtree, false, &substitutions);

	if (hasComponent!Block(mod, subtree))
		for (size_t i = 0; i < daLength(getComponent!Block(mod, out_).related); ++i) {
			immutable e = getComponent!Block(mod, out_).related[i];
			deepCopyCopyComponents(mod, e, out_, substitutions, reverseSubstitutions, extra);
		}

	if (extra !is null)
		extra(out_, subtree);
}

private EntityId deepCopyBuildStructure(ref Module mod, EntityId subtree,
	ref EntityMap substitutions, ref EntityMap reverseSubstitutions) @trusted
{
	immutable out_ = addEntity(mod);
	assert(!substitutions.contains(subtree));
	substitutions.set(subtree, out_);
	reverseSubstitutions.set(out_, subtree);

	if (hasComponent!Block(mod, subtree)) {
		addComponent!Block(mod, out_);
		for (size_t i = 0; i < daLength(getComponent!Block(mod, subtree).related); ++i) {
			immutable child = getComponent!Block(mod, subtree).related[i];
			immutable copied = deepCopyBuildStructure(mod, child, substitutions, reverseSubstitutions);
			auto related = &getComponent!Block(mod, out_).related;
			fp.dynarray.pushBack(*related, copied);
		}
	}

	return out_;
}

/// Copies `subtree` (and everything under it) into a fresh set of entities
/// parented to `subtree`'s own parent block.
EntityId deepCopy(ref Module mod, EntityId subtree, ExtraCopyInstructions extra = null) {
	EntityMap substitutions, reverseSubstitutions;
	scope(exit) { substitutions.free(); reverseSubstitutions.free(); }

	immutable blockEntity = getComponent!Parent(mod, subtree).related[0];
	immutable out_ = deepCopyBuildStructure(mod, subtree, substitutions, reverseSubstitutions);
	deepCopyCopyComponents(mod, out_, blockEntity, substitutions, reverseSubstitutions, extra);
	return out_;
}


// ---------------------------------------------------------------------------
// Builder-level merges
// ---------------------------------------------------------------------------

/// Moves every child of `source`'s block into this one, reparenting them.
ref BlockBuilder moveExisting(return ref BlockBuilder self, ref BlockBuilder source) @trusted {
	auto mod = self.mod;
	assert(hasComponent!Block(*mod, self.block));
	assert(hasComponent!Block(*mod, source.block));

	immutable srcCount = daLength(getComponent!Block(*mod, source.block).related);
	foreach (i; 0 .. srcCount) {
		immutable e = getComponent!Block(*mod, source.block).related[i];
		auto dest = &getComponent!Block(*mod, self.block).related;
		fp.dynarray.pushBack(*dest, e);
	}
	fp.dynarray.clear(getComponent!Block(*mod, source.block).related);

	// Make sure they are labeled as having the new block as their parent
	foreach (i; 0 .. daLength(getComponent!Block(*mod, self.block).related)) {
		immutable e = getComponent!Block(*mod, self.block).related[i];
		getOrAddComponent!Parent(*mod, e).related[0] = self.block;
	}
	return self;
}

/// Deep-copies every child of `source`'s block into this one.
ref BlockBuilder copyExisting(return ref BlockBuilder self, ref const BlockBuilder source, bool skipParameters = false) @trusted {
	auto mod = self.mod;
	assert(hasComponent!Block(*mod, self.block));
	assert(hasComponent!Block(*mod, source.block));

	EntityMap substitutions, reverseSubstitutions;
	scope(exit) { substitutions.free(); reverseSubstitutions.free(); }

	immutable start = daLength(getComponent!Block(*mod, self.block).related);
	immutable sourceCount = daLength(getComponent!Block(*mod, source.block).related);

	foreach (i; 0 .. sourceCount) {
		auto e = getComponent!Block(*mod, source.block).related[i];
		if (skipParameters && hasComponent!FunctionParameter(*mod, e)) continue;
		e = deepCopyBuildStructure(*mod, e, substitutions, reverseSubstitutions);
		auto related = &getComponent!Block(*mod, self.block).related;
		fp.dynarray.pushBack(*related, e);
	}

	for (size_t i = start; i < daLength(getComponent!Block(*mod, self.block).related); ++i) {
		immutable e = getComponent!Block(*mod, self.block).related[i];
		deepCopyCopyComponents(*mod, e, self.block, substitutions, reverseSubstitutions, null);
	}

	return self;
}


// ===========================================================================
// The builtin global block (interface.global_block.cpp)
// ===========================================================================

private void orFlags(ref Module mod, EntityId e, ushort bits) {
	getOrAddComponent!Flags(mod, e).flags |= bits;
}

/// Fills `self`'s block with the language's builtins. Returns `self` so it
/// chains off `createBlockBuilder` the way the C++ did.
ref BlockBuilder buildBuiltinBlock(return ref BlockBuilder self) @trusted {
	auto mod = self.mod;

	const pointerSizedInterned = internIn(*mod, "pointer_sized");
	const valueInterned = internIn(*mod, "value");
	const tInterned = internIn(*mod, "T");

	auto typeBuilder = pushType(self, internIn(*mod, "type"));
	immutable type = typeBuilder.end();
	orFlags(*mod, type, Flags.Comptime | Flags.AlwaysComptime);

	auto blockBuilder = pushType(self, internIn(*mod, "block"));
	immutable blk = blockBuilder.end();
	orFlags(*mod, blk, Flags.Comptime | Flags.AlwaysComptime);

	auto voidBuilder = pushType(self, internIn(*mod, "void"));
	voidBuilder.end();

	immutable earlyInclude = pushCommon(*mod, self.block, internIn(*mod, "early_include"));

	auto compiler = pushNamespace(self, internIn(*mod, "compiler"));

	Lookup[2] pairInputs = [Lookup(pointerSizedInterned), Lookup(pointerSizedInterned)];
	InternedString[2] sizeAlignNames = [internIn(*mod, "size_bits"), internIn(*mod, "align_bits")];
	immutable baseTypeT = pushFunctionType(compiler, internIn(*mod, "base_type_t"),
		pairInputs[], type, true, sizeAlignNames[]);
	orFlags(*mod, baseTypeT, Flags.Comptime);
	immutable baseType = pushValuelessFunction(compiler, internIn(*mod, "base_type"), baseTypeT);
	immutable comptimeBaseType = pushValuelessFunction(compiler, internIn(*mod, "comptime_base_type"), baseTypeT);

	immutable sixtyfour = pushNumber(compiler, InternedString("_"), pointerSizedInterned, size_t.sizeof * 8);
	Lookup[2] sixtyfourPair = [Lookup(sixtyfour), Lookup(sixtyfour)];
	immutable pointerSized = pushCall(compiler, pointerSizedInterned, type, baseType, sixtyfourPair[]);

	immutable eight = pushNumber(compiler, InternedString("_"), pointerSized, 8);
	Lookup[2] eightPair = [Lookup(eight), Lookup(eight)];
	immutable byte_ = pushCall(compiler, internIn(*mod, "byte"), type, baseType, eightPair[]);
	immutable bytePointer = pushPointer(compiler, internIn(*mod, "byte_pointer"), byte_);

	Lookup[1] bytePointerOnly = [Lookup(bytePointer)];
	immutable earlyIncludeT = pushFunctionType(compiler, internIn(*mod, "early_include_t"),
		bytePointerOnly[], pointerSized, true);
	orFlags(*mod, earlyIncludeT, Flags.Comptime);
	attachValuelessFunction(*mod, earlyInclude, earlyIncludeT);

	pushNumber(compiler, internIn(*mod, "current_entity"), pointerSized, 0);

	Lookup[1] byteOnly = [Lookup(byte_)];
	immutable emitT = pushFunctionType(compiler, internIn(*mod, "emit_t"), byteOnly[], byte_, true);
	orFlags(*mod, emitT, Flags.Comptime);
	pushValuelessFunction(compiler, internIn(*mod, "emit"), emitT);

	immutable emitBytesT = pushFunctionType(compiler, internIn(*mod, "emit_bytes_t"),
		bytePointerOnly[], byte_, true);
	orFlags(*mod, emitBytesT, Flags.Comptime);
	pushValuelessFunction(compiler, internIn(*mod, "emit_bytes"), emitBytesT);

	Lookup[2] pointerSizedPair = [Lookup(pointerSized), Lookup(pointerSized)];
	InternedString[2] valueArgNames = [valueInterned, internIn(*mod, "arg")];
	immutable bitwiseT = pushFunctionType(compiler, internIn(*mod, "bitwise_t"),
		pointerSizedPair[], pointerSized, true, valueArgNames[]);
	orFlags(*mod, bitwiseT, Flags.Comptime);
	pushValuelessFunction(compiler, internIn(*mod, "bitwise_and"), bitwiseT);
	pushValuelessFunction(compiler, internIn(*mod, "shift_right"), bitwiseT);

	Lookup[1] typeOnly = [Lookup(type)];
	InternedString[1] tOnlyNames = [tInterned];
	immutable returnT = pushFunctionType(compiler, internIn(*mod, "return_t"),
		typeOnly[], tInterned, true, tOnlyNames[]);
	pushFunction(compiler, internIn(*mod, "indicate_return"), returnT, true).end();
	pushFunction(compiler, internIn(*mod, "indicate_yield"), returnT, true).end();

	immutable pointerT = pushFunctionType(compiler, internIn(*mod, "pointer_t"),
		typeOnly[], tInterned, true, tOnlyNames[]);
	orFlags(*mod, pointerT, Flags.Comptime);
	pushFunction(compiler, internIn(*mod, "pointer"), pointerT, true).end();
	pushFunction(compiler, internIn(*mod, "always_inline"), pointerT, true).end();
	pushFunction(compiler, internIn(*mod, "always_comptime"), pointerT, true).end();

	Lookup[2] typeAndT = [Lookup(type), Lookup(tInterned)];
	InternedString[2] tValueNames = [tInterned, valueInterned];
	immutable debugPrintT = pushFunctionType(compiler, internIn(*mod, "debug_print_t"),
		typeAndT[], byte_, true, tValueNames[]);
	pushFunction(compiler, internIn(*mod, "debug_print"), debugPrintT, true).end();

	auto assembler = pushNamespace(compiler, internIn(*mod, "assembler"));
	immutable register = pushCall(assembler, internIn(*mod, "register"), type, comptimeBaseType, sixtyfourPair[]);

	// NOTE: `inputs`/`names` are deliberately still the (64, 64) pair and the
	// (T, value) names from `debug_print` here - the C++ has the reassignment
	// commented out, and `register_for_t` is built from whatever was left over.
	immutable registerForT = pushFunctionType(assembler, internIn(*mod, "register_for_t"),
		sixtyfourPair[], register, true, tValueNames[]);
	orFlags(*mod, registerForT, Flags.Comptime);
	pushFunction(assembler, internIn(*mod, "register_for"), registerForT, true).end();

	InternedString[1] wildcardName = [InternedString("_")];
	immutable returnRegisterT = pushFunctionType(assembler, internIn(*mod, "return_register_t"),
		typeOnly[], register, true, wildcardName[]);
	orFlags(*mod, returnRegisterT, Flags.Comptime);
	pushFunction(assembler, internIn(*mod, "return_register"), returnRegisterT, true).end();
	pushFunction(assembler, internIn(*mod, "yield_register"), returnRegisterT, true).end();

	Lookup[3] pinRegisterInputs = [Lookup(type), Lookup(tInterned), Lookup(register)];
	InternedString[3] pinRegisterNames = [tInterned, valueInterned, internIn(*mod, "register")];
	immutable pinRegisterT = pushFunctionType(assembler, internIn(*mod, "pin_register_t"),
		pinRegisterInputs[], returnRegisterT, true, pinRegisterNames[]);
	pushFunction(assembler, internIn(*mod, "pin_register"), pinRegisterT, true).end();

	Lookup[0] noInputs;
	immutable beginRegisterAllocationT = pushFunctionType(assembler,
		internIn(*mod, "begin_register_allocation_t"), noInputs[], register, true);
	pushFunction(assembler, internIn(*mod, "begin_register_allocation"), beginRegisterAllocationT, true).end();

	return self;
}


// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
// Ported from tests/block_builder.test.cpp, tests/lookup_resolve.test.cpp,
// tests/copy_components.test.cpp and the alias-resolution cases of
// tests/spec_syntax.test.cpp.

version (unittest) {
	import tests.pipeline_helper;
	import tests.pipeline_helper;

	private EntityId resolveName(ref Fixture f, const(char)[] name) {
		return resolveLookupName(f.mod, internIn(f.mod, name), f.root);
	}

	private bool blockContains(ref Module mod, EntityId blockEntity, EntityId e) {
		auto block = &getComponent!Block(mod, blockEntity);
		foreach (i; 0 .. daLength(block.related))
			if (block.related[i] == e) return true;
		return false;
	}
}

unittest { // pushNumber attaches TypeOf, Number and marks the entity comptime
	auto f = makeModuleWithBuiltins();
	scope(exit) free(f.mod);
	immutable type = resolveName(f, "compiler.byte");
	assert(type != invalidEntity);

	auto builder = createBlockBuilder(f.mod);
	immutable e = pushNumber(builder, internIn(f.mod, "n"), type, 42);

	assert(hasComponent!TypeOf(f.mod, e));
	assert(getComponent!TypeOf(f.mod, e).related[0] == type);
	assert(hasComponent!Number(f.mod, e));
	assert(getComponent!Number(f.mod, e).value == 42);
	assert(flagsSet(f.mod, e, Flags.Comptime));
}

unittest { // pushString attaches TypeOf, DString and marks the entity comptime
	auto f = makeModuleWithBuiltins();
	scope(exit) free(f.mod);
	immutable type = resolveName(f, "compiler.byte_pointer");
	assert(type != invalidEntity);

	auto builder = createBlockBuilder(f.mod);
	auto value = internIn(f.mod, "hello world");
	immutable e = pushString(builder, internIn(f.mod, "s"), type, value);

	assert(hasComponent!DString(f.mod, e));
	assert(getComponent!DString(f.mod, e).value == value);
	assert(flagsSet(f.mod, e, Flags.Comptime));
}

unittest { // pushValueless attaches TypeOf and the Valueless flag, no number/string
	auto f = makeModuleWithBuiltins();
	scope(exit) free(f.mod);
	immutable type = resolveName(f, "compiler.byte");

	auto builder = createBlockBuilder(f.mod);
	immutable e = pushValueless(builder, internIn(f.mod, "v"), type);

	assert(flagsSet(f.mod, e, Flags.Valueless));
	assert(!hasComponent!Number(f.mod, e));
	assert(!hasComponent!DString(f.mod, e));
}

unittest { // pushCommon skips the name component for the discard identifier "_"
	auto f = makeModuleWithBuiltins();
	scope(exit) free(f.mod);
	immutable type = resolveName(f, "compiler.byte");

	auto builder = createBlockBuilder(f.mod);
	immutable e = pushNumber(builder, internIn(f.mod, "_"), type, 1);

	assert(!hasComponent!Name(f.mod, e));
}

unittest { // pushNumber attaches a parent pointing back at the containing block
	auto f = makeModuleWithBuiltins();
	scope(exit) free(f.mod);
	immutable type = resolveName(f, "compiler.byte");

	auto builder = createBlockBuilder(f.mod);
	immutable blockEntity = builder.block;
	immutable e = pushNumber(builder, internIn(f.mod, "n"), type, 1);

	assert(hasComponent!Parent(f.mod, e));
	assert(getComponent!Parent(f.mod, e).related[0] == blockEntity);
	assert(blockContains(f.mod, blockEntity, e));
}

unittest { // pushSubblock creates a nested block whose entities are only visible inside it
	auto f = makeModuleWithBuiltins();
	scope(exit) free(f.mod);
	immutable type = resolveName(f, "compiler.byte");

	auto builder = createBlockBuilder(f.mod);
	auto sub = pushSubblock(builder, internIn(f.mod, "s"), type);
	immutable inner = pushNumber(sub, internIn(f.mod, "n"), type, 5);
	immutable subEntity = sub.end();

	assert(hasComponent!Block(f.mod, subEntity));
	assert(blockContains(f.mod, subEntity, inner));
	assert(!blockContains(f.mod, builder.block, inner));
}

unittest { // pushAlias attaches a resolved alias relation
	auto f = makeModuleWithBuiltins();
	scope(exit) free(f.mod);
	immutable type = resolveName(f, "compiler.byte");

	auto builder = createBlockBuilder(f.mod);
	immutable target = pushValueless(builder, internIn(f.mod, "target"), type);
	immutable e = pushAlias(builder, internIn(f.mod, "aliased"), target);

	assert(hasComponent!Alias(f.mod, e));
	assert(getComponent!Alias(f.mod, e).related[0] == target);
}

unittest { // pushNamespace marks the entity as a Namespace with an (initially empty) block
	auto f = makeModuleWithBuiltins();
	scope(exit) free(f.mod);
	auto builder = createBlockBuilder(f.mod);
	auto ns = pushNamespace(builder, internIn(f.mod, "ns"));
	immutable nsEntity = ns.end();

	assert(flagsSet(f.mod, nsEntity, Flags.Namespace));
	assert(hasComponent!Block(f.mod, nsEntity));
	assert(daLength(getComponent!Block(f.mod, nsEntity).related) == 0);
}

unittest { // pushPointer preserves the requested bounds size
	auto f = makeModuleWithBuiltins();
	scope(exit) free(f.mod);
	immutable byteType = resolveName(f, "compiler.byte");
	assert(byteType != invalidEntity);

	auto builder = createBlockBuilder(f.mod);
	immutable e = pushPointer(builder, internIn(f.mod, "bounded_ptr"), byteType, 8);

	assert(hasComponent!Pointer(f.mod, e));
	assert(getComponent!Pointer(f.mod, e).related[0] == byteType);
	assert(getComponent!Pointer(f.mod, e).size == 8);
}

unittest { // pushPointer still defaults to an unbounded (size 0) pointer
	auto f = makeModuleWithBuiltins();
	scope(exit) free(f.mod);
	immutable byteType = resolveName(f, "compiler.byte");

	auto builder = createBlockBuilder(f.mod);
	immutable e = pushPointer(builder, internIn(f.mod, "unbounded_ptr"), byteType);

	assert(getComponent!Pointer(f.mod, e).size == 0);
}

unittest { // resolves a dotted path into the compiler namespace
	auto f = makeModuleWithBuiltins();
	scope(exit) free(f.mod);
	assert(resolveLookupName(f.mod, internIn(f.mod, "compiler.debug_print"), f.root) != invalidEntity);
}

unittest { // resolves nested namespaces (compiler.assembler.*)
	auto f = makeModuleWithBuiltins();
	scope(exit) free(f.mod);
	assert(resolveLookupName(f.mod, internIn(f.mod, "compiler.assembler.pin_register"), f.root) != invalidEntity);
}

unittest { // resolving an unknown name returns invalidEntity rather than failing
	auto f = makeModuleWithBuiltins();
	scope(exit) free(f.mod);
	assert(resolveLookupName(f.mod, internIn(f.mod, "this.does.not.exist"), f.root) == invalidEntity);
}

unittest { // resolving a Lookup leaves already-resolved entries untouched
	auto f = makeModuleWithBuiltins();
	scope(exit) free(f.mod);
	auto alreadyResolved = Lookup(EntityId(123));
	assert(resolveLookup(f.mod, alreadyResolved, f.root) == 123);
}

unittest { // `type` is resolvable and is flagged AlwaysComptime
	auto f = makeModuleWithBuiltins();
	scope(exit) free(f.mod);
	immutable type = resolveLookupName(f.mod, internIn(f.mod, "type"), f.root);
	assert(type != invalidEntity);
	assert(flagsSet(f.mod, type, Flags.AlwaysComptime));
}

unittest {
	// Resolves a dotted path through an alias to a namespace. `findNamespace`
	// used to check the Namespace flag directly on the entity it found by name,
	// without resolving through an alias first - so `ns2 : alias = ns` could not
	// be used as a namespace segment in `ns2.val` at all.
	auto f = makeModuleWithBuiltins();
	scope(exit) free(f.mod);
	auto builder = createBlockBuilder(f.mod);

	auto ns = pushNamespace(builder, internIn(f.mod, "ns"));
	immutable val = pushNumber(ns, internIn(f.mod, "val"), internIn(f.mod, "compiler.byte"), 42);
	immutable nsEntity = ns.end();
	pushAlias(builder, internIn(f.mod, "ns2"), nsEntity);

	assert(resolveLookupName(f.mod, internIn(f.mod, "ns2.val"), builder.block) == val);
}

unittest { // typeModifiers contains pointer, always_inline and always_comptime
	auto f = makeModuleWithBuiltins();
	scope(exit) free(f.mod);
	auto modifiers = typeModifiers(f.mod, f.root);

	immutable pointer = resolveLookupName(f.mod, internIn(f.mod, "compiler.pointer"), f.root);
	immutable alwaysInline = resolveLookupName(f.mod, internIn(f.mod, "compiler.always_inline"), f.root);
	assert(pointer != invalidEntity);
	assert(alwaysInline != invalidEntity);

	bool hasPointer, hasAlwaysInline;
	foreach (m; modifiers) {
		if (m == pointer) hasPointer = true;
		if (m == alwaysInline) hasAlwaysInline = true;
	}
	assert(hasPointer);
	assert(hasAlwaysInline);
}


// --- aliases in real parsed source ------------------------------------------
//
// "I think the codebase is very un alias safe" - these drive real source text
// through the full compile pipeline with an alias substituted somewhere a
// direct reference would normally go (as a type, as a namespace segment).

unittest { // an alias can be the type of a constant assignment
	auto r = compile("t : alias = compiler.byte\n%1 : t = 0x41\n%2 : t = compiler.emit(%1)\n");
	scope(exit) free(r.mod);
	assert(r.ok);
	static immutable ubyte[1] expected = [0x41];
	assert(emits(r, expected[]));
}

unittest { // an alias can be the type of an undefined assignment
	auto r = compile("t : alias = compiler.byte\nx : t\n");
	scope(exit) free(r.mod);
	assert(r.ok);

	immutable x = find(r.mod, r.root, "x");
	assert(x != invalidEntity);
	assert(flagsSet(r.mod, x, Flags.Valueless));
}

unittest { // a multi-hop alias chain resolves fully
	auto r = compile(
		"a : alias = compiler.byte\nb : alias = a\nc : alias = b\n"
		~ "%1 : c = 0x42\n%2 : c = compiler.emit(%1)\n");
	scope(exit) free(r.mod);
	assert(r.ok);
	static immutable ubyte[1] expected = [0x42];
	assert(emits(r, expected[]));
}

unittest {
	// A dotted lookup through an alias to a namespace resolves in parsed source.
	// `resolveLookups` resolves every lookup's *name* into an entity in place but
	// doesn't convert LookupAlias into an Alias component - that materialization
	// is the later `lookupsResolved` pass. So while `resolveLookups` is still
	// running, `m`'s own alias may still be an unresolved LookupAlias at the
	// point some *other* entity's dotted lookup (`m.val`) needs to walk through
	// it. `resolveAlias` handles this by resolving an unmaterialized
	// LookupAlias segment's name on the spot.
	auto r = compile(
		"math : namespace = {\n\tval : compiler.byte = 0x43\n}\n"
		~ "m : alias = math\n"
		~ "%1 : compiler.byte = compiler.emit(m.val)\n");
	scope(exit) free(r.mod);
	assert(r.ok);
	static immutable ubyte[1] expected = [0x43];
	assert(emits(r, expected[]));
}

unittest { // copies name, flags, type_of and number onto the destination entity
	auto f = makeModuleWithBuiltins();
	scope(exit) free(f.mod);
	immutable byteType = resolveLookupName(f.mod, internIn(f.mod, "compiler.byte"), f.root);

	auto builder = createBlockBuilder(f.mod);
	immutable src = pushNumber(builder, internIn(f.mod, "original"), byteType, 7);
	immutable dest = addEntity(f.mod);

	copyComponents(f.mod, dest, src);

	assert(hasComponent!Name(f.mod, dest));
	assert(getComponent!Name(f.mod, dest).value.view == "original");
	assert(hasComponent!Number(f.mod, dest));
	assert(getComponent!Number(f.mod, dest).value == 7);
	assert(hasComponent!TypeOf(f.mod, dest));
	assert(getComponent!TypeOf(f.mod, dest).related[0] == byteType);
}

unittest { // remaps relation targets through the substitutions map when provided
	auto f = makeModuleWithBuiltins();
	scope(exit) free(f.mod);
	immutable byteType = resolveLookupName(f.mod, internIn(f.mod, "compiler.byte"), f.root);

	auto builder = createBlockBuilder(f.mod);
	immutable otherType = pushValueless(builder, internIn(f.mod, "other_type"), byteType);
	immutable src = pushNumber(builder, internIn(f.mod, "original"), otherType, 1);
	immutable remappedType = addEntity(f.mod);
	immutable dest = addEntity(f.mod);

	EntityMap substitutions;
	scope(exit) substitutions.free();
	substitutions.set(otherType, remappedType);
	copyComponents(f.mod, dest, src, true, &substitutions);

	assert(hasComponent!TypeOf(f.mod, dest));
	assert(getComponent!TypeOf(f.mod, dest).related[0] == remappedType);
}

unittest {
	// Copying an entity with an unresolved LookupAlias and no substitutions map
	// does not crash. (The C++ used to dereference `substitutions->contains(...)`
	// unconditionally in this one branch, without the `if(substitutions)`
	// null-check every other branch uses - a guaranteed null dereference for the
	// default argument.)
	auto f = makeModuleWithBuiltins();
	scope(exit) free(f.mod);

	immutable src = addEntity(f.mod);
	addComponent!LookupAlias(f.mod, src).lookup = internIn(f.mod, "some.unresolved.name");
	immutable dest = addEntity(f.mod);

	copyComponents(f.mod, dest, src);

	// With no substitutions supplied, copyComponents (consistent with every
	// other branch under the same condition) leaves the destination's
	// LookupAlias default-constructed rather than copying the source's value.
	assert(hasComponent!LookupAlias(f.mod, dest));
}
