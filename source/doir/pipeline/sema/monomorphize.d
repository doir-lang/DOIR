/// `sema.monomorphizeFunctions`: gives each distinct set of comptime arguments
/// a copy of the function it was passed to, with those parameters substituted
/// away.
///
/// A comptime parameter is one whose type is always-comptime (C-Type) - `type`
/// and `block` carry the flag natively, and `type.comptime(T)` is how anything
/// else gets it. Such a parameter is not present in the ABI of the resulting
/// function, so a function that has one is not really one function: it is a
/// family, one member per set of arguments it is ever called with, and this is
/// the pass that writes the members out.
///
/// The bookkeeping goes on the *original*: `Monomorphizations` lists every copy
/// made from it, and each copy carries `MonomorphizedFor` - the arguments it
/// was made for. A call looks for itself in that list before making anything,
/// so two calls with the same comptime arguments share one copy. That is what
/// keeps this from being exponential in a module that calls `execute_if(blk, c)`
/// two hundred times with the same block.
///
/// A copy is appended to the *original's own block*, as a local function of the
/// function it specializes - so a family of them stays under the declaration it
/// came from rather than spreading through the block around it. Two things
/// follow, and both are enforced rather than assumed: `MonomorphizedFor` marks a
/// copy as never itself a candidate, and the copies are lifted out of the block
/// while a new one is taken, or each copy would contain every copy before it.
///
/// Where it belongs is the same answer as `sema.typeCheck`: scheduled by the
/// backend, after comptime - which is when the arguments are known - and before
/// `opt.inlineFunctions`, which would otherwise copy the *unspecialized* body
/// in and leave nothing to specialize.
///
/// It is *not* in `mizuSchedule` or in `mizu.doir`'s copy of it, and that is
/// deliberate rather than an oversight. C-Type makes a parameter comptime when
/// its type is always-comptime, and `compiler.assembler.register` is built with
/// `comptime_base_type` - so by the rule as stated, `emit_register(r)` has a
/// comptime parameter and earns a copy per register, which is 256 of them for
/// no gain, and `mizu.doir` stops compiling. The rule is right and the pass
/// implements it; what is missing is a reason to *decline* a specialization
/// that buys nothing, and that is a policy question rather than a bug in
/// either. Until there is one, a schedule that wants this names
/// `monomorphizeFunctions` itself.
module doir.pipeline.sema.monomorphize;

import ecrs.storage : EntityId, invalidEntity;

static import fp.dynarray;
import fp.dynarray : daLength = length;
import fp.string : strFree = free, strSlice = slice;

import doir.interface_;
import doir.module_;
import doir.string_helpers : InternedString, text;
import doir.systems : fixedPointChanged, ownedByCurrentLowering;

import doir.pipeline.canon.sort : loweringThrowawayBlock;

@nogc nothrow:


/// Whether a parameter of type `type` is a comptime parameter (C-Type): every
/// value of it is compile-time known, so there is nothing to pass at runtime.
private bool isComptimeParameter(ref Module mod, EntityId type) {
	immutable base = baseType(mod, resolveTypeModifications(mod, type));
	if (base == invalidEntity) return false;
	return flagsSet(mod, base, Flags.AlwaysComptime);
}

/// Whether `argument` is something this pass may bake into a copy.
///
/// A type always counts, as it does everywhere else in the comptime rules
/// (C-Call). Anything else has to carry the flag the comptime fixpoint settled
/// on it; if it does not, the call is ill-formed and `sema.validateComptime`
/// has already said so, so there is nothing to gain from specializing on it.
private bool isComptimeArgument(ref Module mod, EntityId argument) {
	if (hasComponent!TypeDefinition(mod, argument)) return true;
	return flagsSet(mod, argument, Flags.Comptime);
}

/// The positions of `ft`'s comptime parameters, in order.
private size_t* comptimePositions(ref Module mod, EntityId ft) @trusted {
	size_t* positions = null;
	if (!hasComponent!FunctionInputs(mod, ft)) return positions;

	auto params = &getComponent!FunctionInputs(mod, ft);
	foreach (i; 0 .. daLength(params.related))
		if (isComptimeParameter(mod, params.related[i]))
			fp.dynarray.pushBack(positions, i);

	return positions;
}

/// Whether `f`'s block holds anything but its own parameter declarations and
/// the specializations already made from it.
///
/// Both exclusions are the same point: neither is something a copy of `f` would
/// specialize. The parameters are what gets substituted away, and a nested
/// specialization is a sibling of the copy being considered.
private bool hasBodyBeyondParameters(ref Module mod, EntityId f) @trusted {
	auto block = &getComponent!Block(mod, f);
	foreach (i; 0 .. daLength(block.related)) {
		immutable child = block.related[i];
		if (hasComponent!FunctionParameter(mod, child)) continue;
		if (hasComponent!MonomorphizedFor(mod, child)) continue;
		return true;
	}
	return false;
}

/// Whether `copy` was made for exactly `key`.
private bool madeFor(ref Module mod, EntityId copy, const(EntityId)[] key) @trusted {
	if (!hasComponent!MonomorphizedFor(mod, copy)) return false;

	auto made = &getComponent!MonomorphizedFor(mod, copy);
	if (daLength(made.related) != key.length) return false;

	foreach (i; 0 .. key.length)
		if (resolveAlias(mod, made.related[i]) != key[i]) return false;

	return true;
}

/// The existing specialization of `original` for `key`, or `invalidEntity`.
private EntityId findMonomorphization(ref Module mod, EntityId original, const(EntityId)[] key) @trusted {
	if (!hasComponent!Monomorphizations(mod, original)) return invalidEntity;

	auto made = &getComponent!Monomorphizations(mod, original);
	foreach (i; 0 .. daLength(made.related)) {
		immutable copy = made.related[i];
		if (madeFor(mod, copy, key)) return copy;
	}
	return invalidEntity;
}

/// `original`'s name with the specialization's number on it, so the copies are
/// distinguishable in a dump and do not collide under `sema.nameReuse`.
private InternedString monomorphizedName(ref Module mod, EntityId original, size_t index) @trusted {
	const(char)[] base = hasComponent!Name(mod, original)
		? getComponent!Name(mod, original).value.view
		: "_";

	char* spelled = text(base, "$", index);
	scope(exit) strFree(spelled);
	return internIn(mod, strSlice(spelled));
}

/// Whether position `i` is one of the comptime positions.
private bool isAt(const(size_t)[] positions, size_t i) {
	foreach (p; positions) if (p == i) return true;
	return false;
}

/// The function type `copy` should have: `ft` without its comptime parameters.
///
/// A fresh entity rather than an edit of `ft`, because `ft` is still the
/// original's type and the original is still callable - specializing one call
/// does not retype the function everybody else is calling.
private EntityId reducedFunctionType(ref Module mod, EntityId parent, EntityId ft,
	const(size_t)[] positions, InternedString name) @trusted
{
	auto declared = &getComponent!FunctionInputs(mod, ft);
	immutable count = daLength(declared.related);

	EntityId* inputs = null;
	scope(exit) if (inputs !is null) fp.dynarray.free(inputs);
	InternedString* names = null;
	scope(exit) if (names !is null) fp.dynarray.free(names);

	immutable hasNames = hasComponent!FunctionParameterNames(mod, ft)
		&& getComponent!FunctionParameterNames(mod, ft).length == count;

	foreach (i; 0 .. count) {
		if (isAt(positions, i)) continue;
		fp.dynarray.pushBack(inputs, declared.related[i]);
		if (hasNames)
			fp.dynarray.pushBack(names, getComponent!FunctionParameterNames(mod, ft).slice[i]);
	}

	EntityId returnType = hasComponent!FunctionReturnType(mod, ft)
		? getComponent!FunctionReturnType(mod, ft).related[0]
		: invalidEntity;

	auto block = BlockBuilder(parent, &mod);
	EntityId[0] noInputs;
	immutable reduced = pushFunctionType(block, name,
		inputs is null ? noInputs[] : inputs[0 .. daLength(inputs)],
		returnType, returnType != invalidEntity,
		names is null ? null : names[0 .. daLength(names)]);

	// `always_inline` and friends are properties of the function type, and the
	// specialization is the same function - so it inlines, or does not, exactly
	// as the original did.
	if (hasComponent!Flags(mod, ft))
		getOrAddComponent!Flags(mod, reduced).flags |= getComponent!Flags(mod, ft).flags;

	return reduced;
}

/// Copies `original`, substitutes `key` into its comptime parameters, and files
/// the result under both components.
///
/// The copy comes out with the comptime parameters *gone* - from its body, from
/// its function type, and (at the call site) from the call itself. That is what
/// "not present in the ABI of the resulting function" means, and it is also the
/// only shape the rest of the pipeline can handle: `opt.inlineFunctions` pairs
/// arguments against `associatedParameters` by index, so a copy that kept the
/// declarations while the call dropped the arguments would be read off the end.
private EntityId monomorphize(ref Module mod, EntityId original, EntityId ft,
	const(size_t)[] positions, const(EntityId)[] key) @trusted
{
	immutable parent = findParent(mod, original);
	if (parent == invalidEntity) return invalidEntity;

	immutable declCount = daLength(getComponent!FunctionInputs(mod, ft).related);

	immutable index = hasComponent!Monomorphizations(mod, original)
		? daLength(getComponent!Monomorphizations(mod, original).related)
		: 0;
	auto name = monomorphizedName(mod, original, index);

	immutable reduced = reducedFunctionType(mod, parent, ft, positions,
		monomorphizedName(mod, ft, index));

	// The specializations already made from `original` live in `original`'s own
	// block, so `deepCopy` - which walks that block - would copy them too, and
	// the copy after that would copy those copies. Lift them out for the
	// duration: they are siblings of the one being made, not part of what it
	// specializes.
	EntityId* previous = null;
	scope(exit) if (previous !is null) fp.dynarray.free(previous);
	{
		auto related = &getComponent!Block(mod, original).related;
		for (size_t i = daLength(*related); i-- > 0;)
			if (hasComponent!MonomorphizedFor(mod, (*related)[i])) {
				fp.dynarray.pushBack(previous, (*related)[i]);
				fp.dynarray.removeAt(*related, i);
			}
	}

	immutable copy = deepCopy(mod, original);

	// `deepCopy` parents the copy but does not list it, so where it goes is the
	// caller's to say: the back of the original's own block, a local function of
	// the function it specializes. Nothing looks one up by name - the call that
	// asked for it is repointed at the entity - so nesting costs nothing, and it
	// keeps a family of specializations together under the declaration they came
	// from instead of spread through the block around it.
	{
		auto related = &getComponent!Block(mod, original).related;
		// `previous` came off the back first, so it is in reverse block order.
		for (size_t i = daLength(previous); i-- > 0;)
			fp.dynarray.pushBack(*related, previous[i]);
		fp.dynarray.pushBack(*related, copy);
		getOrAddComponent!Parent(mod, copy).related[0] = original;
	}

	getOrAddComponent!Name(mod, copy).value = name;

	// The copy's own parameters, not the original's - `deepCopy` made new
	// entities for them, and it is those the copied body refers to.
	auto parameters = associatedParameters(mod, declCount, copy);
	scope(exit) if (parameters !is null) fp.dynarray.free(parameters);
	if (daLength(parameters) != declCount) return invalidEntity;

	EntityMap substitutions;
	scope(exit) doir.module_.free(substitutions);
	foreach (i, position; positions)
		substitutions.set(parameters[position], key[i]);
	substituteEntities(mod, copy, substitutions);

	// `substituteEntities` rewrites every relation it reaches, the copy's own
	// block list included - so where each comptime parameter was *declared*
	// there is now a second mention of the argument, which lives somewhere else
	// entirely. Those entries are what has to go; the references it rewrote
	// inside the body are the point of the exercise.
	{
		auto related = &getComponent!Block(mod, copy).related;
		for (size_t i = daLength(*related); i-- > 0;)
			foreach (argument; key)
				if ((*related)[i] == argument) {
					fp.dynarray.removeAt(*related, i);
					break;
				}
	}

	// The survivors close the gaps the removed parameters left, because
	// `associatedParameters` finds a parameter by asking for index `i` and every
	// caller counts from zero.
	{
		auto related = &getComponent!Block(mod, copy).related;
		size_t next = 0;
		foreach (i; 0 .. daLength(*related)) {
			immutable child = (*related)[i];
			if (!hasComponent!FunctionParameter(mod, child)) continue;
			getComponent!FunctionParameter(mod, child).index = next++;
		}
	}

	getOrAddComponent!TypeOf(mod, copy).related[0] = reduced;

	{
		auto made = &addComponent!MonomorphizedFor(mod, copy);
		foreach (argument; key) fp.dynarray.pushBack(made.related, argument);
	}
	{
		auto all = &getOrAddComponent!Monomorphizations(mod, original);
		fp.dynarray.pushBack(all.related, copy);
	}

	return copy;
}

/// Drops the comptime arguments from `call`, which the specialization it now
/// points at no longer declares.
private void dropComptimeArguments(ref Module mod, EntityId call, const(size_t)[] positions) @trusted {
	auto arguments = &getComponent!FunctionInputs(mod, call).related;
	for (size_t i = daLength(*arguments); i-- > 0;)
		if (isAt(positions, i))
			fp.dynarray.removeAt(*arguments, i);
}


/// Whether `subtree` is a call this pass has work to do on, and if so what the
/// work is: `original`, `ft`, the comptime parameter positions and the argument
/// entities at them.
///
/// Split out because the pass runs it twice - once to find the calls without
/// touching anything, and once to act on them.
private bool candidate(ref Module mod, EntityId subtree, out EntityId original,
	out EntityId ft, out size_t* positions, out EntityId* key) @trusted
{
	if (!hasComponent!Call(mod, subtree)) return false;
	if (!hasComponent!FunctionInputs(mod, subtree)) return false;

	original = resolveAlias(mod, getComponent!Call(mod, subtree).related[0]);

	// A specialization is not itself specialized again: its comptime parameters
	// are gone, substituted by the values it was made for.
	if (hasComponent!MonomorphizedFor(mod, original)) return false;

	// There has to be a body to copy, and something in it to specialize.
	//
	// The second half is not a nicety: `pushFunction` gives a builtin an empty
	// block so that its parameters have somewhere to live, so
	// `compiler.indicate_return` - which takes a `type` - looks exactly like a
	// generic function whose every call has earned a copy. Substituting into a
	// body that declares nothing but its own parameters produces the original
	// back, one entity at a time.
	if (!hasComponent!Block(mod, original)) return false;
	if (!hasBodyBeyondParameters(mod, original)) return false;

	// A body is copied from wherever it was declared, which the walk that
	// reached this call does not bound - so ask the walk's own question about
	// the callee, exactly as `opt.inlineFunctions` does.
	if (!ownedByCurrentLowering(mod, original)) return false;

	auto declType = typeOfLookup(mod, original);
	if (!declType.resolved()) return false;
	ft = resolveTypeModifications(mod, declType.entity());
	if (ft == invalidEntity || !hasComponent!FunctionInputs(mod, ft)) return false;

	// The function type's own veto. A comptime parameter is a *reason* to
	// specialize, not an obligation to, and the function is the only thing that
	// knows whether a copy of it would be worth having.
	if (flagsSet(mod, ft, Flags.NeverMonomorphize)) return false;

	positions = comptimePositions(mod, ft);
	if (daLength(positions) == 0) {
		if (positions !is null) fp.dynarray.free(positions);
		positions = null;
		return false;
	}

	// Arity is `sema.functionArity`'s to report. Reading past the end of a call
	// it already rejected would be this pass inventing a second diagnostic about
	// the same line, in the form of a crash.
	auto arguments = &getComponent!FunctionInputs(mod, subtree);
	immutable declCount = daLength(getComponent!FunctionInputs(mod, ft).related);
	if (daLength(arguments.related) != declCount) {
		fp.dynarray.free(positions);
		positions = null;
		return false;
	}

	foreach (i; 0 .. daLength(positions)) {
		immutable argument = resolveAlias(mod, arguments.related[positions[i]]);
		if (!isComptimeArgument(mod, argument)) {
			fp.dynarray.free(positions);
			positions = null;
			if (key !is null) { fp.dynarray.free(key); key = null; }
			return false;
		}
		fp.dynarray.pushBack(key, argument);
	}

	return true;
}


/// An ordinary visitor, scheduled with `sorted!` - the walker the codebase
/// already uses for a pass that adds entities as it goes
/// (`canon.processEarlyInclude` is the other one).
///
/// It has to be `sorted` and not `depthFirst`: specializing a call allocates
/// entities and splices a declaration into the block the original sits in, and
/// a walker that is part way through iterating that block's `related` list
/// rewrites its own footing. `sorted` walks the contiguous id range the sort
/// established instead, re-reading the block each step, so an insert under it
/// is a resize rather than a wrong index - and its `sortWhenFinished` puts the
/// copies back in order afterwards. The copies land past the end of the range
/// this walk covers, so they are not themselves candidates and one pass
/// settles.
bool monomorphizeFunctions(ref Module mod, EntityId subtree) @trusted {
	// Same reasoning as `sema.typeCheck`: the comptime evaluator lowers each
	// block it builds with this schedule, and a copy made down there would be
	// spliced into a tree that is about to be thrown away.
	if (loweringThrowawayBlock()) return true;

	EntityId original, ft;
	size_t* positions = null;
	EntityId* key = null;
	scope(exit) {
		if (positions !is null) fp.dynarray.free(positions);
		if (key !is null) fp.dynarray.free(key);
	}

	if (!candidate(mod, subtree, original, ft, positions, key)) return true;

	auto keySlice = key[0 .. daLength(key)];
	auto positionSlice = positions[0 .. daLength(positions)];

	immutable existing = findMonomorphization(mod, original, keySlice);
	if (existing != invalidEntity) {
		if (existing == original) return true;
		getComponent!Call(mod, subtree).related[0] = existing;
		dropComptimeArguments(mod, subtree, positionSlice);
		return true;
	}

	immutable copy = monomorphize(mod, original, ft, positionSlice, keySlice);
	if (copy == invalidEntity) return true;

	getComponent!Call(mod, subtree).related[0] = copy;
	dropComptimeArguments(mod, subtree, positionSlice);

	// The copy is a subtree nothing has walked yet, and repointing this call may
	// let something else fold.
	fixedPointChanged() = true;
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
	/// `f : (c: type, v: compiler.byte) -> compiler.byte = { }`, which has one
	/// comptime parameter because `type` is always-comptime.
	private EntityId pushGeneric(ref Fixture f) {
		auto block = BlockBuilder(f.root, &f.mod);
		immutable byte_ = resolveLookupName(f.mod, internIn(f.mod, "compiler.byte"), f.root);
		immutable type = resolveLookupName(f.mod, internIn(f.mod, "type"), f.root);

		EntityId[2] inputs = [type, byte_];
		InternedString[2] names = [internIn(f.mod, "c"), internIn(f.mod, "v")];
		immutable ft = pushFunctionType(block, internIn(f.mod, "g_t"),
			inputs[], cast(EntityId) byte_, true, names[]);

		auto builder = pushFunction(block, internIn(f.mod, "g"), ft, true);
		// A body with something in it besides the parameters, or the pass
		// correctly declines: substituting into a body that is only its own
		// parameters gives the original back.
		pushNumber(builder.builder, internIn(f.mod, "local"), byte_, 1);
		return builder.end();
	}

	private EntityId callWith(ref Fixture f, EntityId callee, EntityId typeArgument) {
		auto block = BlockBuilder(f.root, &f.mod);
		immutable byte_ = resolveLookupName(f.mod, internIn(f.mod, "compiler.byte"), f.root);
		immutable value = pushNumber(block, internIn(f.mod, "v"), byte_, 1);
		EntityId[2] arguments = [typeArgument, value];
		return pushCall(block, InternedString("_"), byte_, callee, arguments[]);
	}
}

unittest { // a comptime argument gets the function a copy of its own
	auto f = makeModuleWithBuiltins();
	scope(exit) freeModule(f.mod);
	diagnostics().clear();

	immutable generic = pushGeneric(f);
	immutable type = resolveLookupName(f.mod, internIn(f.mod, "type"), f.root);
	immutable call = callWith(f, generic, type);

	assert(monomorphizeFunctions(f.mod, call));
	assert(hasComponent!Monomorphizations(f.mod, generic));

	auto made = &getComponent!Monomorphizations(f.mod, generic);
	assert(daLength(made.related) == 1);

	immutable copy = made.related[0];
	assert(copy != generic);
	assert(hasComponent!MonomorphizedFor(f.mod, copy));
	assert(getComponent!Call(f.mod, call).related[0] == copy);
}

unittest { // two calls with the same comptime argument share one copy
	auto f = makeModuleWithBuiltins();
	scope(exit) freeModule(f.mod);
	diagnostics().clear();

	immutable generic = pushGeneric(f);
	immutable type = resolveLookupName(f.mod, internIn(f.mod, "type"), f.root);

	immutable first = callWith(f, generic, type);
	immutable second = callWith(f, generic, type);

	assert(monomorphizeFunctions(f.mod, first));
	assert(monomorphizeFunctions(f.mod, second));

	assert(daLength(getComponent!Monomorphizations(f.mod, generic).related) == 1);
	assert(getComponent!Call(f.mod, first).related[0]
		== getComponent!Call(f.mod, second).related[0]);
}

unittest { // two different comptime arguments get two copies
	auto f = makeModuleWithBuiltins();
	scope(exit) freeModule(f.mod);
	diagnostics().clear();

	immutable generic = pushGeneric(f);
	immutable type = resolveLookupName(f.mod, internIn(f.mod, "type"), f.root);
	immutable blk = resolveLookupName(f.mod, internIn(f.mod, "block"), f.root);

	immutable first = callWith(f, generic, type);
	immutable second = callWith(f, generic, blk);

	assert(monomorphizeFunctions(f.mod, first));
	assert(monomorphizeFunctions(f.mod, second));

	auto made = &getComponent!Monomorphizations(f.mod, generic);
	assert(daLength(made.related) == 2);
	assert(made.related[0] != made.related[1]);
	assert(getComponent!Call(f.mod, first).related[0]
		!= getComponent!Call(f.mod, second).related[0]);
}

unittest { // a function with no comptime parameter is left alone
	auto f = makeModuleWithBuiltins();
	scope(exit) freeModule(f.mod);
	diagnostics().clear();

	auto block = BlockBuilder(f.root, &f.mod);
	immutable byte_ = resolveLookupName(f.mod, internIn(f.mod, "compiler.byte"), f.root);

	EntityId[1] inputs = [byte_];
	InternedString[1] names = [internIn(f.mod, "v")];
	immutable ft = pushFunctionType(block, internIn(f.mod, "plain_t"),
		inputs[], cast(EntityId) byte_, true, names[]);
	auto plainBuilder = pushFunction(block, internIn(f.mod, "plain"), ft, true);
	pushNumber(plainBuilder.builder, internIn(f.mod, "local"), byte_, 1);
	immutable plain = plainBuilder.end();

	immutable value = pushNumber(block, internIn(f.mod, "v2"), byte_, 1);
	EntityId[1] arguments = [value];
	immutable call = pushCall(block, InternedString("_"), byte_, plain, arguments[]);

	assert(monomorphizeFunctions(f.mod, call));
	assert(!hasComponent!Monomorphizations(f.mod, plain));
	assert(getComponent!Call(f.mod, call).related[0] == plain);
}

unittest {
	// A copy is a local function of what it specializes, and a second copy does
	// not contain the first - which it would, since `deepCopy` walks the block
	// the copies are being appended to.
	auto f = makeModuleWithBuiltins();
	scope(exit) freeModule(f.mod);
	diagnostics().clear();

	immutable generic = pushGeneric(f);
	immutable type = resolveLookupName(f.mod, internIn(f.mod, "type"), f.root);
	immutable blk = resolveLookupName(f.mod, internIn(f.mod, "block"), f.root);

	assert(monomorphizeFunctions(f.mod, callWith(f, generic, type)));
	assert(monomorphizeFunctions(f.mod, callWith(f, generic, blk)));

	auto made = &getComponent!Monomorphizations(f.mod, generic);
	assert(daLength(made.related) == 2);

	bool contains(EntityId block, EntityId e) {
		auto children = &getComponent!Block(f.mod, block).related;
		foreach (i; 0 .. daLength(*children))
			if ((*children)[i] == e) return true;
		return false;
	}

	foreach (i; 0 .. 2) {
		immutable copy = made.related[i];
		assert(getComponent!Parent(f.mod, copy).related[0] == generic);
		assert(contains(generic, copy));
	}
	assert(!contains(made.related[0], made.related[1]));
	assert(!contains(made.related[1], made.related[0]));

	// ...and a copy is never a candidate itself, however comptime the call.
	immutable nested = callWith(f, made.related[0], type);
	assert(monomorphizeFunctions(f.mod, nested));
	assert(!hasComponent!Monomorphizations(f.mod, made.related[0]));
}

unittest { // `never_monomorphize` on the function type declines the copy
	auto f = makeModuleWithBuiltins();
	scope(exit) freeModule(f.mod);
	diagnostics().clear();

	immutable generic = pushGeneric(f);
	immutable type = resolveLookupName(f.mod, internIn(f.mod, "type"), f.root);
	immutable call = callWith(f, generic, type);

	immutable ft = getComponent!TypeOf(f.mod, generic).related[0];
	getOrAddComponent!Flags(f.mod, ft).flags |= Flags.NeverMonomorphize;

	assert(monomorphizeFunctions(f.mod, call));
	assert(!hasComponent!Monomorphizations(f.mod, generic));
	assert(getComponent!Call(f.mod, call).related[0] == generic);
}

unittest {
	// A body that declares nothing but its own parameters is what every builtin
	// looks like - `pushFunction` gives them an empty block so the parameters
	// have somewhere to live - and substituting into one gives the original
	// back. Declined without needing a marker.
	auto f = makeModuleWithBuiltins();
	scope(exit) freeModule(f.mod);
	diagnostics().clear();

	auto block = BlockBuilder(f.root, &f.mod);
	immutable byte_ = resolveLookupName(f.mod, internIn(f.mod, "compiler.byte"), f.root);
	immutable type = resolveLookupName(f.mod, internIn(f.mod, "type"), f.root);

	EntityId[2] inputs = [type, byte_];
	InternedString[2] names = [internIn(f.mod, "c"), internIn(f.mod, "v")];
	immutable ft = pushFunctionType(block, internIn(f.mod, "empty_t"),
		inputs[], cast(EntityId) byte_, true, names[]);
	immutable empty = pushFunction(block, internIn(f.mod, "empty"), ft, true).end();

	immutable call = callWith(f, empty, type);
	assert(monomorphizeFunctions(f.mod, call));
	assert(!hasComponent!Monomorphizations(f.mod, empty));
}

unittest { // a builtin has no body to copy, so nothing happens to it
	auto f = makeModuleWithBuiltins();
	scope(exit) freeModule(f.mod);
	diagnostics().clear();

	auto block = BlockBuilder(f.root, &f.mod);
	immutable byte_ = resolveLookupName(f.mod, internIn(f.mod, "compiler.byte"), f.root);
	immutable emit = resolveLookupName(f.mod, internIn(f.mod, "compiler.emit"), f.root);

	immutable value = pushNumber(block, internIn(f.mod, "v"), byte_, 1);
	EntityId[1] arguments = [value];
	immutable call = pushCall(block, InternedString("_"), byte_, emit, arguments[]);

	assert(monomorphizeFunctions(f.mod, call));
	assert(!hasComponent!Monomorphizations(f.mod, emit));
}
