/// `sema.computeTypeProperties`: fills in the size and alignment of every
/// aggregate, once, after comptime.
///
/// M-Freeze is what makes this a pass rather than a query. Every modifier is a
/// comptime call, so once the comptime fixpoint has settled `Phi(t)` and the
/// layout of `t` are fixed for the rest of the compilation and there is exactly
/// one answer per type. Before that point there is not: P2 says a comptime read
/// of a property sees the flags written above it, so a `size_of` either side of
/// a `type.pack` folds to two different constants, and those reads are the
/// comptime evaluator's to answer, not this pass's.
///
/// Like `sema.typeCheck` this is scheduled by the backend rather than by
/// `canonicalizeSchedule` - layout is an ABI question, and a backend that lays
/// aggregates out differently replaces this pass instead of arguing with it.
///
/// Sizes are in *bits* throughout, because `compiler.base_type(size, align)` is
/// (`compiler.byte` is `base_type(8, 8)`), and mixing the two units silently
/// would be worse than carrying the odd one.
module doir.pipeline.sema.type_properties;

import ecrs.storage : EntityId, invalidEntity;

import fp.dynarray : daLength = length;

import doir.interface_;
import doir.module_;

@nogc nothrow:


/// How deep a nest of aggregates-within-aggregates is followed before giving
/// up. A recursive type reaches itself through a *pointer*, which has a size of
/// its own and stops the descent, so anything this catches is a type that
/// genuinely contains itself - already ill-formed, and not worth a cycle set to
/// diagnose here.
private enum size_t maxDepth = 64;

/// The size of a pointer on the target, in bits, read off `compiler.pointer_sized`.
size_t pointerSizeBits(ref Module mod, EntityId root) {
	immutable pointerSized = resolveCached(mod, "compiler.pointer_sized", root);
	if (pointerSized == invalidEntity) return 0;
	if (!hasComponent!TypeDefinition(mod, pointerSized)) return 0;
	return getComponent!TypeDefinition(mod, pointerSized).size;
}

/// `size` rounded up to a multiple of `alignment`.
private size_t alignUp(size_t size, size_t alignment) {
	if (alignment == 0) return size;
	immutable remainder = size % alignment;
	return remainder == 0 ? size : size + (alignment - remainder);
}

/// The size of `type` in bits, computing it if nothing has yet.
size_t typeSizeBits(ref Module mod, EntityId type, size_t depth = 0) @trusted {
	if (depth > maxDepth) return 0;
	type = resolveAlias(mod, type);
	if (type == invalidEntity) return 0;

	// An array carries its bound; a plain pointer is one machine pointer.
	if (hasComponent!Pointer(mod, type)) {
		auto pointer = &getComponent!Pointer(mod, type);
		if (pointer.size == 0) return pointerSizeBits(mod, type);
		return pointer.size * typeSizeBits(mod, pointer.related[0], depth + 1);
	}

	if (!hasComponent!TypeDefinition(mod, type)) return 0;
	computeLayout(mod, type, depth);
	return getComponent!TypeDefinition(mod, type).size;
}

/// Ditto, for alignment.
size_t typeAlignmentBits(ref Module mod, EntityId type, size_t depth = 0) @trusted {
	if (depth > maxDepth) return 0;
	type = resolveAlias(mod, type);
	if (type == invalidEntity) return 0;

	if (hasComponent!Pointer(mod, type)) {
		auto pointer = &getComponent!Pointer(mod, type);
		if (pointer.size == 0) return pointerSizeBits(mod, type);
		return typeAlignmentBits(mod, pointer.related[0], depth + 1);
	}

	if (!hasComponent!TypeDefinition(mod, type)) return 0;
	computeLayout(mod, type, depth);
	return getComponent!TypeDefinition(mod, type).alignment;
}

/// Lays `type`'s fields out and writes the result back into its
/// `TypeDefinition`, unless something already did.
///
/// A type built by `compiler.base_type` arrives with both already set and is
/// left alone - the point of a base type is that its layout is *given*, not
/// derived. So is an aggregate with no fields, whose size really is zero.
private void computeLayout(ref Module mod, EntityId type, size_t depth) @trusted {
	auto definition = &getComponent!TypeDefinition(mod, type);
	if (definition.size != 0 || definition.alignment != 0) return;
	if (!hasComponent!Block(mod, type)) return;
	// A function type that refers to its own parameters carries a block holding
	// them (`canon.materializeFunctionTypeParameters`). Those are parameters,
	// not fields, and a function type has no layout of its own anyway.
	if (hasComponent!FunctionInputs(mod, type)) return;

	auto block = &getComponent!Block(mod, type);
	immutable fieldCount = daLength(block.related);
	if (fieldCount == 0) return;

	immutable union_ = flagsSet(mod, type, Flags.Union);

	size_t size = 0;
	size_t alignment = 0;

	foreach (i; 0 .. fieldCount) {
		immutable field = block.related[i];
		// Only a form-7 declaration is a field. Anything else the author wrote
		// inside the braces - a nested type, an alias, a comptime call the
		// evaluator has not stripped - describes the type rather than occupying
		// space in it.
		if (!hasComponent!TypeOf(mod, field)) continue;
		if (hasComponent!TypeDefinition(mod, field)) continue;

		immutable fieldType = getComponent!TypeOf(mod, field).related[0];
		immutable fieldSize = typeSizeBits(mod, fieldType, depth + 1);
		immutable fieldAlignment = typeAlignmentBits(mod, fieldType, depth + 1);

		if (fieldAlignment > alignment) alignment = fieldAlignment;

		// M-Flag's `type.union`: the fields overlap rather than following one
		// another, so the aggregate is as big as its largest member - and they
		// all begin at zero.
		if (union_) {
			getOrAddComponent!FieldOffset(mod, field).offsetBits = 0;
			if (fieldSize > size) size = fieldSize;
		} else {
			size = alignUp(size, fieldAlignment);
			getOrAddComponent!FieldOffset(mod, field).offsetBits = size;
			size += fieldSize;
		}
	}

	definition.alignment = alignment;
	definition.size = alignUp(size, alignment);
}


/// The bit offset of `field` within the aggregate that declares it, as
/// `computeLayout` recorded it while laying that aggregate out.
///
/// `size_t.max` when `field` is not a field of an aggregate, which is what
/// `mizu.doir.field_offset_bits` reports on rather than guessing at zero.
///
/// The layout is computed here if nothing has yet, so an offset can be asked
/// for without waiting for `computeTypeProperties` to come round to the type.
size_t fieldOffsetBits(ref Module mod, EntityId field) @trusted {
	if (!isAggregateField(mod, field)) return size_t.max;

	computeLayout(mod, getComponent!Parent(mod, field).related[0], 0);
	if (!hasComponent!FieldOffset(mod, field)) return size_t.max;
	return getComponent!FieldOffset(mod, field).offsetBits;
}


bool computeTypeProperties(ref Module mod, EntityId subtree) @trusted {
	if (!hasComponent!TypeDefinition(mod, subtree)) return true;
	computeLayout(mod, subtree, 0);
	return true;
}


// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest) {
	import doir.diagnostics : diagnostics;
	import tests.pipeline_helper;
}

version (unittest) {
	/// A field of `type` named `name`, as the parser's form-7 declaration is.
	private EntityId pushField(ref Module mod, EntityId aggregate, string name, EntityId fieldType) {
		immutable field = pushCommon(mod, aggregate, internIn(mod, name));
		addComponent!TypeOf(mod, field).related[0] = fieldType;
		addComponent!Flags(mod, field).flags = Flags.Valueless;
		return field;
	}

	/// A base type of a given layout.
	///
	/// Built by hand rather than taken from `compiler.byte`, which in a bare
	/// fixture is still an unfolded `compiler.base_type(8, 8)` call - folding it
	/// is `opt.computeCompilerNamespace`'s job, and happens during lowering.
	private EntityId pushBase(ref BlockBuilder block, string name, size_t size, size_t alignment) {
		immutable t = pushType(block, internIn(*block.mod, name)).end();
		auto definition = &getComponent!TypeDefinition(*block.mod, t);
		definition.size = size;
		definition.alignment = alignment;
		return t;
	}
}

unittest { // an aggregate is the sum of its fields, padded to their alignment
	auto f = makeModuleWithBuiltins();
	scope(exit) freeModule(f.mod);

	auto block = BlockBuilder(f.root, &f.mod);
	immutable byte_ = pushBase(block, "b8", 8, 8);
	immutable word = pushBase(block, "w32", 32, 32);

	immutable pair = pushType(block, internIn(f.mod, "pair")).end();
	pushField(f.mod, pair, "a", byte_);
	pushField(f.mod, pair, "b", byte_);

	assert(computeTypeProperties(f.mod, pair));
	assert(getComponent!TypeDefinition(f.mod, pair).size == 16);
	assert(getComponent!TypeDefinition(f.mod, pair).alignment == 8);

	// A byte, then a word: the word's alignment pads the byte out to 32 before
	// it starts, and the aggregate takes the widest alignment in it.
	immutable padded = pushType(block, internIn(f.mod, "padded")).end();
	pushField(f.mod, padded, "small", byte_);
	pushField(f.mod, padded, "large", word);

	assert(computeTypeProperties(f.mod, padded));
	assert(getComponent!TypeDefinition(f.mod, padded).size == 64);
	assert(getComponent!TypeDefinition(f.mod, padded).alignment == 32);
}

unittest { // every field records where it begins, on the same walk
	auto f = makeModuleWithBuiltins();
	scope(exit) freeModule(f.mod);

	auto block = BlockBuilder(f.root, &f.mod);
	immutable byte_ = pushBase(block, "b8", 8, 8);
	immutable word = pushBase(block, "w32", 32, 32);

	immutable padded = pushType(block, internIn(f.mod, "padded")).end();
	immutable small = pushField(f.mod, padded, "small", byte_);
	immutable large = pushField(f.mod, padded, "large", word);

	assert(computeTypeProperties(f.mod, padded));
	// The byte starts at zero; the word's own alignment pads it out to 32
	// rather than letting it follow at 8, which is the same sum the size is
	// computed from.
	assert(getComponent!FieldOffset(f.mod, small).offsetBits == 0);
	assert(getComponent!FieldOffset(f.mod, large).offsetBits == 32);
	assert(fieldOffsetBits(f.mod, small) == 0);
	assert(fieldOffsetBits(f.mod, large) == 32);

	// The type itself is not a field of anything, and neither is a base type.
	assert(fieldOffsetBits(f.mod, padded) == size_t.max);
	assert(fieldOffsetBits(f.mod, byte_) == size_t.max);
}

unittest { // a union's fields all begin at zero, being overlapped (M-Flag)
	auto f = makeModuleWithBuiltins();
	scope(exit) freeModule(f.mod);

	auto block = BlockBuilder(f.root, &f.mod);
	immutable byte_ = pushBase(block, "b8", 8, 8);
	immutable word = pushBase(block, "w32", 32, 32);

	immutable either = pushType(block, internIn(f.mod, "either")).end();
	getOrAddComponent!Flags(f.mod, either).flags |= Flags.Union;
	immutable a = pushField(f.mod, either, "a", byte_);
	immutable b = pushField(f.mod, either, "b", word);

	assert(computeTypeProperties(f.mod, either));
	assert(fieldOffsetBits(f.mod, a) == 0);
	assert(fieldOffsetBits(f.mod, b) == 0);
}

unittest { // an offset can be asked for before the layout pass reaches the type
	auto f = makeModuleWithBuiltins();
	scope(exit) freeModule(f.mod);

	auto block = BlockBuilder(f.root, &f.mod);
	immutable word = pushBase(block, "w32", 32, 32);

	immutable pair = pushType(block, internIn(f.mod, "pair")).end();
	pushField(f.mod, pair, "a", word);
	immutable second = pushField(f.mod, pair, "b", word);

	// No `computeTypeProperties` call: `fieldOffsetBits` lays the type out
	// itself, which is what lets a comptime query run ahead of the pass.
	assert(!hasComponent!FieldOffset(f.mod, second));
	assert(fieldOffsetBits(f.mod, second) == 32);
}

unittest { // a union is as big as its largest field, not their sum (M-Flag)
	auto f = makeModuleWithBuiltins();
	scope(exit) freeModule(f.mod);

	auto block = BlockBuilder(f.root, &f.mod);
	immutable byte_ = pushBase(block, "b8", 8, 8);
	immutable word = pushBase(block, "w32", 32, 32);

	immutable u = pushType(block, internIn(f.mod, "u")).end();
	pushField(f.mod, u, "small", byte_);
	pushField(f.mod, u, "large", word);
	getOrAddComponent!Flags(f.mod, u).flags |= Flags.Union;

	assert(computeTypeProperties(f.mod, u));
	assert(getComponent!TypeDefinition(f.mod, u).size == 32);
	assert(getComponent!TypeDefinition(f.mod, u).alignment == 32);
}

unittest { // a layout that is already given is left alone
	auto f = makeModuleWithBuiltins();
	scope(exit) freeModule(f.mod);

	auto block = BlockBuilder(f.root, &f.mod);
	immutable given = pushBase(block, "given", 8, 8);
	// A field that would say otherwise, to prove the given layout wins.
	pushField(f.mod, given, "wide", pushBase(block, "w64", 64, 64));

	assert(computeTypeProperties(f.mod, given));
	assert(getComponent!TypeDefinition(f.mod, given).size == 8);
}

unittest { // an array field is its bound times its element
	auto f = makeModuleWithBuiltins();
	scope(exit) freeModule(f.mod);

	auto block = BlockBuilder(f.root, &f.mod);
	immutable byte_ = pushBase(block, "b8", 8, 8);
	immutable arr = pushPointer(block, internIn(f.mod, "arr"), byte_, 4);

	assert(typeSizeBits(f.mod, arr) == 32);
	assert(typeAlignmentBits(f.mod, arr) == 8);
}

unittest { // a plain pointer is one machine pointer, whatever it points at
	auto r = compile("%1 : compiler.byte = 1\n");
	scope(exit) freeModule(r.mod);
	diagnostics().clear();

	// Through a real compile, so `compiler.pointer_sized` has been folded to a
	// type with a layout rather than left as a `base_type` call.
	immutable pointerBits = pointerSizeBits(r.mod, r.root);
	assert(pointerBits != 0);

	immutable bytePointer = resolveLookupName(r.mod,
		internIn(r.mod, "compiler.byte_pointer"), r.root);
	assert(bytePointer != invalidEntity);
	assert(typeSizeBits(r.mod, bytePointer) == pointerBits);
}
