/// Building a schedule out of a string at runtime: `parseSystem` turns
/// `"sequential(depthFirst(pinRegisters), breadthFirst(allocateRegisters))"`
/// into something callable that `doir.systems` and `ecrs.system` both accept
/// as a system.
///
/// This is the runtime half of the scheduling story `doir.systems` tells at
/// compile time. There, a schedule is spelled as D - `sequential(...)` over
/// walker templates - and the visitor travels as an alias so the walk can
/// inline. That is the right trade for the pipeline's own schedules, which are
/// fixed when the compiler is built; it is no help at all when the schedule
/// arrives as text (a `--schedule` flag, a line in a DOIR source file, a test
/// fixture), because a template argument cannot be a runtime string.
///
/// The split here keeps both: *registration* stays at compile time, so every
/// walk is still the specialized, inlinable one the templates generate, and
/// only *selection* happens at runtime. `passModules` below is enumerated with
/// `__traits(allMembers)`, every member with a pass-shaped signature is
/// instantiated into all three walkers, and the parser picks among the
/// resulting function pointers by name. Nothing has to be listed twice: a pass
/// added to one of those modules is spellable in a schedule string as soon as
/// it compiles, the same way `tests/runner.d` picks up a new unittest.
///
/// What that enumeration goes on is shape, since that is all a signature says:
/// a predicate that happens to read `bool fn(ref Module, EntityId)`
/// (`comptimeValueAvailable`) is registered alongside the passes, and walking
/// one stops the walk the first time it answers "no". Registration is not a
/// claim that a name is worth scheduling - only that it can be.
///
/// The parsed schedule is a flat node array rather than a tree of closures,
/// for the reason every other combinator here is a struct: `-betterC` has no
/// GC to hang a delegate's capture off. It owns that array, so it is freed
/// with `freeSystem`, and - like `Module` - it is a handle, so a copy must not
/// be freed twice.
///
/// Grammar, in full:
///
///     system      := 'sequential' '(' [system {',' system} [',']] ')'
///                  | 'parallel'   '(' [system {',' system} [',']] ')'
///                  | 'fixedPoint' '(' system ')'
///                  | 'applyGlobally' '(' system ')'
///                  | 'depthFirst'   '(' name ')'
///                  | 'breadthFirst' '(' name ')'
///                  | 'sorted'       '(' name [',' ('true' | 'false')] ')'
///                  | name
///
/// Comments are DOIR's own - `//` and `#` to end of line, `/* */` across them -
/// since a schedule is something a program writes in its own source.
///
/// A bare `name` is a whole-module pass (`bool fn(ref Module)`); a name inside
/// a walker is a visitor (`bool fn(ref Module, EntityId)`). `fixedPoint`
/// repeats exactly one system, as the combinator it names does; repeating
/// several is `fixedPoint(sequential(...))`.
///
/// Walks are rooted at whatever `canonicalize.sort` last produced - there is
/// no useful way to write an entity id in a schedule string - unless the
/// caller points `DynamicSystem.subtree` somewhere else. Narrowing a schedule
/// to part of the module is a separate matter and not this field's job; see
/// `doir.systems`' ownership filter, which is what `compiler.run_schedule`
/// uses.
/// `parallel` needs a `ThreadPool` handed to `parseSystem`, degrading to
/// running its systems in order (all of them; see `ecrs.system.parallel`'s note
/// on the short circuit) when it has none.
module doir.dynamic_systems;

import core.stdc.stdio : fprintf, stderr;
import core.stdc.string : memcmp;

static import fp.dynarray;
import fp.dynarray : daLength = length;

static import bc.threadpool;
import bc.threadpool : Job, ThreadPool;

import ecrs.context : Context;
import ecrs.storage : EntityId, invalidEntity;

import std.traits : Parameters;

import diagnose.diagnostics : Ansi;
import doir.diagnostics : DoirAnsi, stringContentsError;
import doir.string_helpers : appendText, text;
import doir.interface_ : currentCanonicalizeRoot;
import doir.module_ : Module, moduleOf;
import doir.systems;

@nogc nothrow:


// ---------------------------------------------------------------------------
// The registry
// ---------------------------------------------------------------------------

/// The modules whose passes a schedule string may name. Anything public in one
/// of them that is shaped like a pass is registered; nothing else has to be
/// said. Mirrors `tests/runner.d`'s module list, and for the same reason: a
/// list of names that maintains itself is the only kind that stays correct.
private enum string[] passModules = [
	"doir.print",
	"doir.pipeline",
	"doir.pipeline.canon.comptime",
	"doir.pipeline.canon.lookup",
	"doir.pipeline.canon.materialize",
	"doir.pipeline.canon.override_fallback_schedule",
	"doir.pipeline.canon.process_early_include",
	"doir.pipeline.canon.sort",
	"doir.pipeline.canon.strip_freestanding_blocks",
	"doir.pipeline.sema.function_arity",
	"doir.pipeline.sema.monomorphize",
	"doir.pipeline.sema.name_reuse",
	"doir.pipeline.sema.strip_names",
	"doir.pipeline.sema.type_check",
	"doir.pipeline.sema.type_deduction",
	"doir.pipeline.sema.type_properties",
	"doir.pipeline.sema.type_variables",
	"doir.pipeline.opt.allocate_registers",
	"doir.pipeline.opt.compute_compiler_namespace",
	"doir.pipeline.opt.inline_functions",
	"doir.pipeline.opt.materialize_aliases",
	"doir.pipeline.opt.pin_registers",
	"doir.pipeline.opt.run_schedule",
	"doir.pipeline.opt.mizu.comptime_evaluate",
	"doir.pipeline.opt.mizu.materialize_immediates",
	"doir.pipeline.opt.mizu.materialize_labels",
];

/// Whether `member` is a pass `mod` actually offers: public, and declared in
/// `mod` itself rather than re-exported into it by a selective import, which
/// would otherwise register one pass twice under two different qualified names.
///
/// The visibility check has to be explicit. `__traits(getMember)` reaches a
/// private symbol regardless, so without it the enumeration would happily
/// register a module's internals under a name the module never published - and
/// then stop compiling the day that changes.
private template ownMember(alias mod, string member) {
	static if (!__traits(compiles, __traits(isSame, __traits(parent, __traits(getMember, mod, member)), mod)))
		enum ownMember = false;
	else static if (!__traits(isSame, __traits(parent, __traits(getMember, mod, member)), mod))
		enum ownMember = false;
	else
		enum ownMember = __traits(getVisibility, __traits(getMember, mod, member)) == "public";
}

/// `bool fn(ref Module, EntityId)`: what the walkers take.
private template isVisitorMember(alias mod, string member) {
	static if (!ownMember!(mod, member))
		enum isVisitorMember = false;
	else
		enum isVisitorMember = __traits(compiles, (ref Module mod_, EntityId e) {
			bool result = __traits(getMember, mod, member)(mod_, e);
		});
}

/// `bool fn(ref Module)`: a whole pass, which a schedule names on its own.
private template isPassMember(alias mod, string member) {
	static if (!ownMember!(mod, member))
		enum isPassMember = false;
	else
		enum isPassMember = __traits(compiles, (ref Module mod_) {
			bool result = __traits(getMember, mod, member)(mod_);
		});
}

/// A visitor with one `bool` of configuration after the entity
/// (`resolveLookups`' `typesOnly`, `computeCompilerNamespace`'s
/// `forceRegisterValues`). The pipeline's own schedules bind those as template
/// arguments; a schedule string binds them by naming `fn!true` / `fn!false`,
/// so both settings are registered as separate visitors.
///
/// The third parameter has to be a `bool` exactly: `EntityId` is a `uint`, so
/// a trailing entity would happily accept `true` and register a pass under a
/// name that silently means "rooted at entity 1".
private template isBoolVisitorMember(alias mod, string member) {
	static if (!ownMember!(mod, member) || isVisitorMember!(mod, member))
		enum isBoolVisitorMember = false;
	else static if (!__traits(compiles, (ref Module mod_, EntityId e) {
		bool result = __traits(getMember, mod, member)(mod_, e, true);
	}))
		enum isBoolVisitorMember = false;
	else
		enum isBoolVisitorMember = is(Parameters!(__traits(getMember, mod, member))[2] == bool);
}

/// One pass as a schedule string can use it: the walks are instantiated here,
/// at compile time, so choosing one at runtime costs an indirect call rather
/// than a generic tree walk over an untyped visitor.
///
/// A pass may be both - `sortSystem`'s root argument has a default - in which
/// case naming it on its own runs the whole pass and naming it inside a walker
/// runs it per entity. The grammar position decides, so neither is ambiguous.
struct RegisteredSystem {
	/// The fully qualified name, as a schedule string spells it.
	string name;
	/// Non-null if the pass can be named on its own.
	bool function(ref Module) @nogc nothrow pass;
	/// Non-null (all four together) if it can be named inside a walker.
	bool function(ref Module, EntityId) @nogc nothrow visit;
	bool function(ref Module, EntityId) @nogc nothrow depthFirst;
	bool function(ref Module, EntityId) @nogc nothrow breadthFirst;
	bool function(ref Module, EntityId, bool) @nogc nothrow sorted;
}

// The wrappers below exist so every registered entry has exactly one signature
// whatever the pass declared: `@trusted` or not, extra defaulted parameters or
// not, `bool` configuration bound or not.

private template passCall(alias fn) {
	bool passCall(ref Module mod) { return fn(mod); }
}

private template visitCall(alias fn) {
	bool visitCall(ref Module mod, EntityId e) { return fn(mod, e); }
}

private template boundVisitCall(alias fn, bool argument) {
	bool boundVisitCall(ref Module mod, EntityId e) { return fn(mod, e, argument); }
}

private template depthFirstWalk(alias visit) {
	bool depthFirstWalk(ref Module mod, EntityId subtree) { return depthFirst!visit(mod, subtree); }
}

private template breadthFirstWalk(alias visit) {
	bool breadthFirstWalk(ref Module mod, EntityId subtree) { return breadthFirst!visit(mod, subtree); }
}

private template sortedWalk(alias visit) {
	bool sortedWalk(ref Module mod, EntityId subtree, bool sortWhenFinished) {
		return sorted!visit(mod, subtree, sortWhenFinished);
	}
}

/// Fills in the walker half of an entry for the already-wrapped `visit`.
private void registerWalks(alias visit)(ref RegisteredSystem entry) {
	entry.visit = &visit;
	entry.depthFirst = &depthFirstWalk!visit;
	entry.breadthFirst = &breadthFirstWalk!visit;
	entry.sorted = &sortedWalk!visit;
}

/// The entry for `mod.member`, in whichever of the two shapes it has.
private RegisteredSystem entryOf(alias mod, string member, string name)() {
	RegisteredSystem entry;
	entry.name = name;
	static if (isPassMember!(mod, member))
		entry.pass = &passCall!(__traits(getMember, mod, member));
	static if (isVisitorMember!(mod, member))
		registerWalks!(visitCall!(__traits(getMember, mod, member)))(entry);
	return entry;
}

/// Ditto, for one setting of a `bool`-configured visitor.
private RegisteredSystem boundEntryOf(alias mod, string member, string name, bool argument)() {
	RegisteredSystem entry;
	entry.name = name;
	registerWalks!(boundVisitCall!(__traits(getMember, mod, member), argument))(entry);
	return entry;
}

/// Extra spellings a schedule may use, as [spelling, the enumerated name it
/// means].
///
/// The enumeration names a pass after the D function implementing it, which is
/// the right default and occasionally the wrong word. `canonicalize.sort` is
/// spelled `sortSystem` in D only because `sort` there hands back the new root
/// rather than a bool, and so is not pass-shaped; a schedule has no reason to
/// carry that distinction around.
private enum string[2][] systemAliases = [
	["sort", "doir.pipeline.canon.sort.sortSystem"],
	["debugPrint", "doir.print.printSystem"],
];

/// The alias spellings that mean `fullName`, if any.
private string[] aliasesOf(string fullName) {
	string[] out_;
	foreach (pair; systemAliases)
		if (pair[1] == fullName) out_ ~= pair[0];
	return out_;
}

/// Every name the enumeration produced, in registration order. Computed by the
/// same enumeration the lookup below runs, so the two cannot disagree; it
/// exists so "is this short name ambiguous" is answered once, at compile time,
/// instead of by a second scan on every lookup.
private string[] collectNames() {
	string[] names;
	static foreach (moduleName; passModules) {{
		alias mod = imported!moduleName;
		static foreach (member; __traits(allMembers, mod)) {
			static if (isVisitorMember!(mod, member) || isPassMember!(mod, member))
				names ~= moduleName ~ "." ~ member;
			else static if (isBoolVisitorMember!(mod, member)) {
				names ~= moduleName ~ "." ~ member ~ "!true";
				names ~= moduleName ~ "." ~ member ~ "!false";
			}
		}
	}}
	return names;
}

private enum string[] enumeratedNames = collectNames();

/// An alias for a pass that does not exist is a typo that would otherwise do
/// nothing at all, quietly, until somebody wrote the alias in a schedule.
static foreach (pair; systemAliases) {
	static assert({
		foreach (name; enumeratedNames)
			if (name == pair[1]) return true;
		return false;
	}(), "no registered pass named " ~ pair[1] ~ " for alias " ~ pair[0]);
}

/// Ditto, plus the alias spellings - everything a schedule may write.
private enum string[] registeredNames = enumeratedNames ~ {
	string[] spellings;
	foreach (pair; systemAliases)
		spellings ~= pair[0];
	return spellings;
}();

/// How many passes a schedule string can name.
enum size_t registeredSystemCount = registeredNames.length;

/// The `index`th registered name, for listing them in an error or a `--help`.
const(char)[] registeredSystemName(size_t index) {
	static foreach (i, name; registeredNames)
		if (index == i) return name;
	return null;
}

/// `name` with everything up to the last `.` removed: what a schedule may
/// abbreviate a pass to when no other pass shares it.
private string shortName(string name) {
	foreach_reverse (i, c; name)
		if (c == '.') return name[i + 1 .. $];
	return name;
}

/// Whether `shortName(name)` picks out exactly one registered pass. Only those
/// may be abbreviated; the rest have to be spelled in full, rather than
/// resolving to whichever happened to be enumerated first.
private bool shortNameIsUnique(string name) {
	size_t matches;
	foreach (other; enumeratedNames)
		if (shortName(other) == shortName(name)) ++matches;
	return matches == 1;
}

private bool equals(const(char)[] a, const(char)[] b) @trusted {
	if (a.length != b.length) return false;
	if (a.length == 0) return true;
	return memcmp(a.ptr, b.ptr, a.length) == 0;
}

/// Whether a schedule spelled `name` means the pass registered as `fullName`.
/// Both the short form and whether it is even allowed are settled at compile
/// time, so the runtime cost is one or two length-checked `memcmp`s.
private template matches(string fullName) {
	bool matches(const(char)[] name) {
		if (equals(name, fullName)) return true;
		static if (shortNameIsUnique(fullName))
			if (equals(name, shortName(fullName))) return true;
		static foreach (spelling; aliasesOf(fullName))
			if (equals(name, spelling)) return true;
		return false;
	}
}

/// Finds the pass `name` refers to, by full name, by an alias spelling, or -
/// where that is unambiguous - by its last component alone.
bool findRegisteredSystem(const(char)[] name, out RegisteredSystem entry) {
	static foreach (moduleName; passModules) {{
		alias mod = imported!moduleName;
		static foreach (member; __traits(allMembers, mod)) {
			static if (isVisitorMember!(mod, member) || isPassMember!(mod, member)) {{
				enum fullName = moduleName ~ "." ~ member;
				if (matches!fullName(name)) {
					entry = entryOf!(mod, member, fullName);
					return true;
				}
			}} else static if (isBoolVisitorMember!(mod, member)) {
				static foreach (argument; [true, false]) {{
					enum fullName = moduleName ~ "." ~ member ~ (argument ? "!true" : "!false");
					if (matches!fullName(name)) {
						entry = boundEntryOf!(mod, member, fullName, argument);
						return true;
					}
				}}
			}
		}
	}}
	return false;
}


// ---------------------------------------------------------------------------
// The parsed schedule
// ---------------------------------------------------------------------------

private enum NodeKind {
	pass,          /// a whole-module pass named on its own
	walk,          /// `depthFirst` / `breadthFirst` over a visitor
	sortedWalk,    /// `sorted`, which carries a flag the others don't
	sequential,
	parallel,
	fixedPoint,
	applyGlobally,
}

private struct Node {
	NodeKind kind;

	// Leaves. Exactly one of these is set, per `kind`. The subtree to walk is
	// not among them: it belongs to the whole schedule (`DynamicSystem.subtree`),
	// since a schedule string has no way to name an entity of its own.
	bool function(ref Module) @nogc nothrow pass;
	bool function(ref Module, EntityId) @nogc nothrow walk;
	bool function(ref Module, EntityId, bool) @nogc nothrow sortedWalk;
	bool sortWhenFinished;

	// Combinators. A range into `DynamicSystem.children` rather than a list of
	// pointers, so growing the node array can't invalidate anything.
	size_t firstChild;
	size_t childCount;
}

/// A schedule parsed from a string: a system, in the sense `doir.systems` and
/// `ecrs.system` mean it, so it can be run directly, stored, or nested inside
/// one of their combinators.
///
/// Owns heap memory - release it with `freeSystem`. It is a handle, like
/// `Module`: copies share the nodes, so only one of them may be freed.
struct DynamicSystem {
	private Node* nodes;
	private size_t* children;
	private size_t rootNode;

	/// The entity every walk in the schedule is rooted at. Left alone it is
	/// `currentCanonicalizeRoot`, which the walkers resolve to whatever
	/// `canonicalize.sort` last produced - the only root a string could have
	/// meant, since it cannot name an entity. Set it to run the schedule over
	/// one subtree instead.
	EntityId subtree = currentCanonicalizeRoot;

	/// The pool `parallel` nodes dispatch on. Null (or single-worker) runs them
	/// in order instead, running every one; see `ecrs.system.parallel`.
	ThreadPool* pool;

	/// What went wrong, or null if the parse succeeded. Points at a string
	/// literal; `errorOffset` / `errorLength` slice the *source* that was
	/// parsed, which this does not own.
	const(char)[] error;
	size_t errorOffset;  /// ditto
	size_t errorLength;  /// ditto

	@nogc nothrow:

	/// Whether the string parsed. A failed parse is still callable; it just
	/// fails, so a caller that reports the error elsewhere need not branch.
	bool valid() const { return error is null; }

	bool opCall(ref Context context) @trusted {
		if (!valid()) return false;
		return runNode(this, rootNode, context);
	}

	/// Ditto, for a module directly - the shape `doir.pipeline`'s schedules use.
	bool opCall(ref Module mod) { return opCall(mod.ctx); }
}

/// Releases a parsed schedule. Named the long way for the reason `freeModule`
/// is: a plain `free` is hidden by any module that declares one of its own.
void freeSystem(ref DynamicSystem system) @trusted {
	if (system.nodes !is null) fp.dynarray.free(system.nodes);
	if (system.children !is null) fp.dynarray.free(system.children);
	system.nodes = null;
	system.children = null;
	system.rootNode = 0;
}

/// Prints `system`'s parse error against the `source` it was parsed from,
/// pointing at the text that caused it.
///
/// For a caller with nothing to hang a diagnostic on - a test, or a schedule
/// that came from a command line rather than out of a DOIR file. A compiler
/// pass has an entity and wants `reportSystemError` instead.
void printSystemError(ref const DynamicSystem system, const(char)[] source,
	const(char)[] what = "<schedule>") @trusted
{
	if (system.valid()) return;

	auto offending = offendingText(system, source);

	fprintf(stderr, "doir: %.*s: %.*s",
		cast(int) what.length, what.ptr,
		cast(int) system.error.length, system.error.ptr);
	if (offending.length > 0)
		fprintf(stderr, ": '%.*s'", cast(int) offending.length, offending.ptr);
	// A byte offset, not a line: a schedule string has no lines of its own, and
	// where it came from is the caller's to say.
	fprintf(stderr, " (at byte %zu)\n", system.errorOffset);
}

/// The text `system`'s error points at, if any.
private const(char)[] offendingText(ref const DynamicSystem system, const(char)[] source) {
	if (system.errorOffset >= source.length) return null;
	auto rest = source[system.errorOffset .. $];
	return rest[0 .. system.errorLength < rest.length ? system.errorLength : rest.length];
}

/// Reports a failed parse the way the rest of the compiler reports anything:
/// as a diagnostic, pointed at the offending text inside the schedule string
/// itself rather than at the call that was handed it.
///
/// `stringEntity` is the string constant the schedule came from - the argument
/// the call was given, not the call. `what` names the builtin for the message.
///
/// A pass wants this and not `printSystemError`. The two say the same thing,
/// but one of them comes out beside every other error the compile raised, with
/// the file, the line and the source quoted under it, and the other is a line
/// on stderr that a schedule written in a DOIR file has no business being
/// reported by.
void reportSystemError(ref Module mod, ref const DynamicSystem system,
	const(char)[] source, EntityId stringEntity, const(char)[] what) @trusted
{
	if (system.valid()) return;

	auto message = text(DoirAnsi.func, what, Ansi.reset, ": ", system.error);
	auto offending = offendingText(system, source);
	if (offending.length > 0)
		appendText(message, ": ", DoirAnsi.info, offending, Ansi.reset);

	stringContentsError(mod, stringEntity, message, system.errorOffset);
}


// ---------------------------------------------------------------------------
// Running one
// ---------------------------------------------------------------------------

/// A subtree of a parsed schedule, in the shape the combinators want: a
/// savable callable taking the context. What `fixedPoint` is handed, so that a
/// repeated schedule goes through `doir.systems.fixedPoint` itself rather than
/// through a second copy of its loop.
private struct NodeSystem {
	private DynamicSystem* system;
	private size_t index;

	@nogc nothrow:
	// Spelled out because a struct with `opCall` loses the literal syntax:
	// `NodeSystem(a, b)` would otherwise be read as a call on `.init`.
	this(DynamicSystem* system, size_t index) { this.system = system; this.index = index; }

	bool opCall(ref Context context) @trusted { return runNode(*system, index, context); }
}

private struct ParallelItem {
	DynamicSystem* system;
	size_t index;
	Context* context;
	bool result = true;
}

private void runParallelItem(void* argument) @nogc nothrow @trusted {
	auto item = cast(ParallelItem*) argument;
	item.result = runNode(*item.system, item.index, *item.context);
}

/// `ecrs.system.parallel(Systems...)` over a list whose length is only known at
/// runtime. The compile-time combinator lays its jobs out in a fixed-size
/// array and recovers each system's type through one trampoline per type;
/// here every branch is already the same type, so the jobs can just be a
/// dynarray of `ParallelItem`.
///
/// It runs every branch, like the combinator it mirrors - a `parallel`
/// schedule has no first failure to stop at - and ANDs the results.
private bool runParallel(ref DynamicSystem system, const Node* node, ref Context context) @trusted {
	immutable count = node.childCount;

	if (system.pool is null || bc.threadpool.workerCount(system.pool) <= 1 || count <= 1) {
		bool valid = true;
		foreach (i; 0 .. count)
			valid &= runNode(system, system.children[node.firstChild + i], context);
		return valid;
	}

	ParallelItem* items = fp.dynarray.create!ParallelItem(count);
	scope(exit) fp.dynarray.free(items);
	Job* jobs = fp.dynarray.create!Job(count);
	scope(exit) fp.dynarray.free(jobs);

	foreach (i; 0 .. count) {
		items[i] = ParallelItem(&system, system.children[node.firstChild + i], &context);
		jobs[i] = Job(&runParallelItem, &items[i]);
	}

	// `run` blocks until every job has finished, so `items` and the schedule
	// both outlive the dispatch.
	bc.threadpool.run(system.pool, jobs[0 .. count]);

	bool valid = true;
	foreach (i; 0 .. count)
		valid &= items[i].result;
	return valid;
}

private bool runNode(ref DynamicSystem system, size_t index, ref Context context) @trusted {
	auto node = &system.nodes[index];
	final switch (node.kind) {
		case NodeKind.pass:
			return node.pass(moduleOf(context));
		case NodeKind.walk:
			return node.walk(moduleOf(context), system.subtree);
		case NodeKind.sortedWalk:
			return node.sortedWalk(moduleOf(context), system.subtree, node.sortWhenFinished);
		case NodeKind.sequential:
			foreach (i; 0 .. node.childCount)
				if (!runNode(system, system.children[node.firstChild + i], context))
					return false;
			return true;
		case NodeKind.parallel:
			return runParallel(system, node, context);
		case NodeKind.fixedPoint:
			return fixedPoint(context, NodeSystem(&system, system.children[node.firstChild]));
		case NodeKind.applyGlobally:
			immutable previousGlobal = beginGlobalLowering();
			scope(exit) endGlobalLowering(previousGlobal);
			return runNode(system, system.children[node.firstChild], context);
	}
}


// ---------------------------------------------------------------------------
// Parsing one
// ---------------------------------------------------------------------------

private struct Parser {
	const(char)[] source;
	size_t position;
	DynamicSystem* system;

	@nogc nothrow:

	bool failed() const { return system.error !is null; }

	/// Records the first failure and unwinds; later ones would only describe
	/// the confusion the first one caused.
	bool fail(const(char)[] message, size_t offset, size_t length = 0) {
		if (!failed()) {
			system.error = message;
			system.errorOffset = offset;
			system.errorLength = length;
		}
		return false;
	}

	/// Whitespace and comments, in DOIR's three forms - `//` and `#` to end of
	/// line, `/* */` across them. A schedule is something a program writes in
	/// its own source, so it is written in a string and read here, and the
	/// comment it is allowed to carry should not depend on which of those two
	/// it is being read by.
	///
	/// An unterminated block comment runs to the end of the text rather than
	/// failing, which is what `doir.parser` does with one.
	void skipSpace() {
		while (position < source.length) {
			immutable c = source[position];
			if (c == ' ' || c == '\t' || c == '\n' || c == '\r'
				|| c == '\v' || c == '\f') {
				++position;
				continue;
			}

			if (c == '#' || (c == '/' && position + 1 < source.length && source[position + 1] == '/')) {
				while (position < source.length && source[position] != '\n')
					++position;
				continue;
			}

			if (c == '/' && position + 1 < source.length && source[position + 1] == '*') {
				position += 2;
				while (position < source.length) {
					if (source[position] == '*' && position + 1 < source.length
						&& source[position + 1] == '/') {
						position += 2;
						break;
					}
					++position;
				}
				continue;
			}

			break;
		}
	}

	bool atEnd() { skipSpace(); return position >= source.length; }

	char peek() { skipSpace(); return position < source.length ? source[position] : '\0'; }

	bool accept(char c) {
		if (peek() != c) return false;
		++position;
		return true;
	}

	/// A name: identifier characters, plus the `.` that qualifies it and the
	/// `!` that binds a `bool`-configured visitor's setting.
	const(char)[] identifier() {
		skipSpace();
		immutable start = position;
		while (position < source.length) {
			immutable c = source[position];
			immutable isNameChar = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
				|| (c >= '0' && c <= '9') || c == '_' || c == '.' || c == '!';
			if (!isNameChar) break;
			++position;
		}
		return source[start .. position];
	}
}

/// Appends `node` and hands back its index.
private size_t addNode(ref Parser parser, Node node) @trusted {
	fp.dynarray.pushBack(parser.system.nodes, node);
	return daLength(parser.system.nodes) - 1;
}

/// Moves `indices` into the schedule's shared child array, giving back the
/// range the parent node stores.
private void adoptChildren(ref Parser parser, scope const size_t[] indices,
	out size_t first, out size_t count) @trusted
{
	first = daLength(parser.system.children);
	count = indices.length;
	foreach (index; indices)
		fp.dynarray.pushBack(parser.system.children, index);
}

/// The name inside a walker, resolved to a visitor.
private bool parseVisitor(ref Parser parser, out RegisteredSystem entry) {
	immutable start = parser.position;
	auto name = parser.identifier();
	if (name.length == 0)
		return parser.fail("expected the name of a pass", parser.position);

	if (!findRegisteredSystem(name, entry))
		return parser.fail("unknown pass", start, name.length);
	if (entry.visit is null)
		return parser.fail("this is a whole-module pass, so it cannot be walked over entities",
			start, name.length);
	return true;
}

/// `true` / `false`, for `sorted`'s re-sort flag.
private bool parseBool(ref Parser parser, out bool value) {
	immutable start = parser.position;
	auto word = parser.identifier();
	if (equals(word, "true")) { value = true; return true; }
	if (equals(word, "false")) { value = false; return true; }
	return parser.fail("expected 'true' or 'false'", start, word.length);
}

private bool parseChildList(ref Parser parser, ref size_t* indices) @trusted {
	if (!parser.accept('('))
		return parser.fail("expected '(' after a combinator", parser.position);

	if (parser.peek() != ')') {
		do {
			// A trailing comma ends the list rather than promising another
			// entry. Without that, commenting out the last step of a schedule
			// leaves a dangling comma and the whole thing stops parsing - which
			// makes comments useless for the one thing they are mostly for.
			if (parser.peek() == ')') break;

			size_t child;
			if (!parseSystemNode(parser, child)) return false;
			fp.dynarray.pushBack(indices, child);
		} while (parser.accept(','));
	}

	if (!parser.accept(')'))
		return parser.fail("expected ',' or ')'", parser.position);
	return true;
}

private bool parseSystemNode(ref Parser parser, out size_t index) @trusted {
	immutable start = parser.position;
	auto name = parser.identifier();
	if (name.length == 0)
		return parser.fail("expected a system", parser.position);

	// Combinators are recognized by name and by the '(' that has to follow, so
	// a pass could in principle share one of their spellings.
	immutable isCall = parser.peek() == '(';

	if (isCall && (equals(name, "depthFirst") || equals(name, "breadthFirst"))) {
		cast(void) parser.accept('(');
		RegisteredSystem entry;
		if (!parseVisitor(parser, entry)) return false;
		if (!parser.accept(')'))
			return parser.fail("expected ')' - a walker takes one pass", parser.position);

		Node node;
		node.kind = NodeKind.walk;
		node.walk = equals(name, "depthFirst") ? entry.depthFirst : entry.breadthFirst;
		index = addNode(parser, node);
		return true;
	}

	if (isCall && equals(name, "sorted")) {
		cast(void) parser.accept('(');
		RegisteredSystem entry;
		if (!parseVisitor(parser, entry)) return false;

		Node node;
		node.kind = NodeKind.sortedWalk;
		node.sortedWalk = entry.sorted;
		if (parser.accept(',') && !parseBool(parser, node.sortWhenFinished)) return false;
		if (!parser.accept(')'))
			return parser.fail("expected ')' - sorted takes a pass and an optional flag",
				parser.position);

		index = addNode(parser, node);
		return true;
	}

	// `fixedPoint` repeats one system, like the combinator it names. A round
	// made of several passes is `fixedPoint(sequential(...))`, spelled out, so
	// that what the round consists of is never implied by a comma.
	if (isCall && equals(name, "fixedPoint")) {
		cast(void) parser.accept('(');

		size_t child;
		if (!parseSystemNode(parser, child)) return false;
		if (!parser.accept(')'))
			return parser.fail("expected ')' - fixedPoint repeats a single system,"
				~ " so several are written fixedPoint(sequential(...))", parser.position);

		Node node;
		node.kind = NodeKind.fixedPoint;
		size_t[1] only = [child];
		adoptChildren(parser, only[], node.firstChild, node.childCount);
		index = addNode(parser, node);
		return true;
	}

	// `applyGlobally` wraps one system, like `fixedPoint`, and for the same reason:
	// what it turns off is a property of the walk, and a comma-separated list
	// would leave it unclear how far the widening reached.
	if (isCall && equals(name, "applyGlobally")) {
		cast(void) parser.accept('(');

		size_t child;
		if (!parseSystemNode(parser, child)) return false;
		if (!parser.accept(')'))
			return parser.fail("expected ')' - applyGlobally widens a single system,"
				~ " so several are written applyGlobally(sequential(...))", parser.position);

		Node node;
		node.kind = NodeKind.applyGlobally;
		size_t[1] only = [child];
		adoptChildren(parser, only[], node.firstChild, node.childCount);
		index = addNode(parser, node);
		return true;
	}

	if (isCall && (equals(name, "sequential") || equals(name, "parallel"))) {
		size_t* indices = null;
		scope(exit) if (indices !is null) fp.dynarray.free(indices);

		if (!parseChildList(parser, indices)) return false;

		Node node;
		node.kind = equals(name, "sequential") ? NodeKind.sequential : NodeKind.parallel;
		adoptChildren(parser, fp.dynarray.slice(indices), node.firstChild, node.childCount);
		index = addNode(parser, node);
		return true;
	}

	if (isCall)
		return parser.fail("not a combinator", start, name.length);

	RegisteredSystem entry;
	if (!findRegisteredSystem(name, entry))
		return parser.fail("unknown system", start, name.length);
	if (entry.pass is null)
		return parser.fail(
			"this pass visits one entity, so it needs a walker around it"
			  ~ " (depthFirst, breadthFirst or sorted)",
			start, name.length);

	Node node;
	node.kind = NodeKind.pass;
	node.pass = entry.pass;
	index = addNode(parser, node);
	return true;
}

/// Builds a system out of `source`.
///
/// `pool` is what any `parallel` in the schedule dispatches on; without one
/// they run their branches in order.
///
/// The result is always callable - check `valid` (or `error`) to find out
/// whether it will do anything - and always owns memory, so it always has to
/// be handed to `freeSystem`. It does not own `source`: the error offsets
/// point back into it.
DynamicSystem parseSystem(const(char)[] source, ThreadPool* pool = null) @trusted {
	DynamicSystem system;
	system.pool = pool;

	auto parser = Parser(source, 0, &system);
	size_t root;
	if (parseSystemNode(parser, root)) {
		if (!parser.atEnd())
			cast(void) parser.fail("unexpected trailing text", parser.position,
				source.length - parser.position);
		else
			system.rootNode = root;
	}

	// A failed parse keeps its nodes: they are freed with everything else, and
	// dropping them here would only make `freeSystem` conditional.
	return system;
}


// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest) {
	import doir.diagnostics : diagnostics;
	import doir.interface_ : createBuilderStack;
	import doir.module_ : createModule, freeModule;
	import doir.parser : parseFile;
	import doir.pipeline : runPipeline;
	import doir.pipeline.canon.sort : newRoot, sort;
	import tests.pipeline_helper : makeTree;

}

unittest { // the enumeration finds the real passes, under their real names
	assert(registeredSystemCount > 0);

	RegisteredSystem entry;

	// A visitor: walkable, not runnable on its own.
	assert(findRegisteredSystem("doir.pipeline.opt.pin_registers.pinRegisters", entry));
	assert(entry.visit !is null && entry.depthFirst !is null && entry.sorted !is null);
	assert(entry.pass is null);

	// A whole pass.
	assert(findRegisteredSystem("doir.pipeline.mizuSchedule", entry));
	assert(entry.pass !is null);

	// `sortSystem`'s root argument has a default, so it is both.
	assert(findRegisteredSystem("doir.pipeline.canon.sort.sortSystem", entry));
	assert(entry.pass !is null && entry.visit !is null);

	// A `bool`-configured visitor is registered once per setting.
	assert(findRegisteredSystem("doir.pipeline.canon.lookup.resolveLookups!true", entry));
	assert(entry.visit !is null);
	assert(findRegisteredSystem("doir.pipeline.opt.compute_compiler_namespace.computeCompilerNamespace!false", entry));
	assert(entry.visit !is null);

	// An alias spelling resolves to the pass it names. `canonicalize.sort` is
	// `sortSystem` in D only because `sort` there hands back the new root, so a
	// schedule that wants a sort should not have to know that.
	assert(findRegisteredSystem("sort", entry));
	assert(equals(entry.name, "doir.pipeline.canon.sort.sortSystem"));
	assert(entry.pass !is null);

	// The last component alone works where it is unambiguous...
	assert(findRegisteredSystem("pinRegisters", entry));
	assert(equals(entry.name, "doir.pipeline.opt.pin_registers.pinRegisters"));

	// ... and nothing resolves a name that was never registered.
	// `canonicalizeSchedule` takes the parser's builder stack as well as the module, and
	// `runPipeline` returns an entity: neither is pass-shaped, so neither is
	// nameable however central it is to a compile.
	assert(!findRegisteredSystem("doir.pipeline.canonicalizeSchedule", entry));
	assert(!findRegisteredSystem("doir.pipeline.runPipeline", entry)); // wrong shape
	assert(!findRegisteredSystem("nonsense", entry));

	// `doir.pipeline`, `doir.pipeline.opt.run_schedule` and
	// `doir.pipeline.canon.override_fallback_schedule` all import their way back
	// here - the registry enumerates them, and they reach into it (the last one
	// reaches back up at `doir.pipeline` as well). A cycle the compiler resolved
	// the wrong way round would not fail to build, it would quietly leave their
	// passes out, so pin one of each.
	assert(findRegisteredSystem("doir.pipeline.mizuSchedule", entry));
	assert(findRegisteredSystem("doir.pipeline.opt.run_schedule.runSchedule", entry));
	assert(findRegisteredSystem(
		"doir.pipeline.canon.override_fallback_schedule.runFallbackSchedule", entry));

	// Every name the registry reports is one it can find again.
	foreach (i; 0 .. registeredSystemCount)
		assert(findRegisteredSystem(registeredSystemName(i), entry));
}

unittest { // a walker parsed from a string walks the way the template does
	auto t = makeTree();
	scope(exit) freeModule(t.mod);
	// A schedule string walks the canonical root, having no way to name an
	// entity, so point it at the fixture's.
	immutable previousRoot = newRoot;
	newRoot = t.root;
	scope(exit) newRoot = previousRoot;

	auto system = parseSystem("depthFirst(doir.pipeline.opt.pin_registers.pinRegisters)");
	scope(exit) freeSystem(system);
	assert(system.valid());
	assert(system(t.mod));

	// The bare name of a visitor is refused, with a message that says what to
	// do about it.
	auto bare = parseSystem("doir.pipeline.opt.pin_registers.pinRegisters");
	scope(exit) freeSystem(bare);
	assert(!bare.valid());
	assert(bare.errorOffset == 0);

	// ... and so is a whole pass handed to a walker.
	auto walked = parseSystem("depthFirst(doir.pipeline.mizuSchedule)");
	scope(exit) freeSystem(walked);
	assert(!walked.valid());
}

unittest { // the combinators nest, and a parsed schedule is itself a system
	static import ecrs.system;

	auto t = makeTree();
	scope(exit) freeModule(t.mod);
	// A schedule string walks the canonical root, having no way to name an
	// entity, so point it at the fixture's.
	immutable previousRoot = newRoot;
	newRoot = t.root;
	scope(exit) newRoot = previousRoot;

	enum schedule = "sequential("
		~ "  fixedPoint(depthFirst(pinRegisters)),"
		~ "  parallel(breadthFirst(pinRegisters), sorted(pinRegisters, false)),"
		~ "  doir.pipeline.canon.sort.sortSystem"
		~ ")";
	auto system = parseSystem(schedule);
	scope(exit) freeSystem(system);
	assert(system.valid());
	assert(system(t.mod));

	// It satisfies libECRS's own combinators, which is the whole point of
	// handing back a system rather than just running the string.
	auto again = parseSystem("depthFirst(pinRegisters)");
	scope(exit) freeSystem(again);
	assert(ecrs.system.sequential(t.mod.ctx, system, again));
}

unittest { // every way of writing it wrong is reported, not run
	static immutable string[] broken = [
		"",
		"   ",
		"sequential(",
		"sequential(depthFirst(pinRegisters)",
		"depthFirst()",
		"depthFirst(nonsense)",
		"depthFirst(pinRegisters, breadthFirst(pinRegisters))",
		"fixedPoint()",
		"fixedPoint(depthFirst(pinRegisters), breadthFirst(pinRegisters))",
		"sorted(pinRegisters, maybe)",
		"nonsense",
		"nonsense(pinRegisters)",
		"depthFirst(pinRegisters) trailing",
	];

	foreach (source; broken) {
		auto system = parseSystem(source);
		scope(exit) freeSystem(system);
		assert(!system.valid());
		assert(system.error.length > 0);
		assert(system.errorOffset <= source.length);
		// A failed parse is still callable, and fails.
		auto mod = createModule();
		scope(exit) freeModule(mod);
		assert(!system(mod));
	}
}

unittest { // comments, in all three of DOIR's forms
	auto t = makeTree();
	scope(exit) freeModule(t.mod);
	// A schedule string walks the canonical root, having no way to name an
	// entity, so point it at the fixture's.
	immutable previousRoot = newRoot;
	newRoot = t.root;
	scope(exit) newRoot = previousRoot;

	enum schedule = "
		sequential(
			// a line comment
			depthFirst(pinRegisters),   # and a hash one
			/* and a block one,
			   across lines */
			breadthFirst(pinRegisters),
			// commenting out the last step leaves the comma behind it, which
			// is why a trailing one has to be allowed
			//depthFirst(pinRegisters),
		)
	";
	auto system = parseSystem(schedule);
	scope(exit) freeSystem(system);
	assert(system.valid());
	assert(system(t.mod));

	// An unterminated block comment runs to the end rather than failing, which
	// is what `doir.parser` does with one - so what precedes it still parses.
	auto unterminated = parseSystem("sequential(depthFirst(pinRegisters)) /* ...");
	scope(exit) freeSystem(unterminated);
	assert(unterminated.valid());

	// A comment is not a name: `//` inside one does not make a system out of
	// what follows it.
	auto commentedOut = parseSystem("// depthFirst(pinRegisters)");
	scope(exit) freeSystem(commentedOut);
	assert(!commentedOut.valid());

	// And a lone `/` is still not anything.
	auto slash = parseSystem("sequential(/)");
	scope(exit) freeSystem(slash);
	assert(!slash.valid());
}

unittest { // whitespace and empty lists
	auto t = makeTree();
	scope(exit) freeModule(t.mod);
	// A schedule string walks the canonical root, having no way to name an
	// entity, so point it at the fixture's.
	immutable previousRoot = newRoot;
	newRoot = t.root;
	scope(exit) newRoot = previousRoot;

	// `sort` is a whole pass, so it stands on its own in a schedule.
	auto sorting = parseSystem("sequential(sort, depthFirst(pinRegisters))");
	scope(exit) freeSystem(sorting);
	assert(sorting.valid());

	// Nothing to do succeeds, matching `ecrs.system.sequential()`.
	auto empty = parseSystem("sequential()");
	scope(exit) freeSystem(empty);
	assert(empty.valid());
	assert(empty(t.mod));

	// A round made of more than one pass has to say so.
	auto spread = parseSystem("
		fixedPoint(
			sequential(
				depthFirst(pinRegisters),
				breadthFirst(pinRegisters)
			)
		)
	");
	scope(exit) freeSystem(spread);
	assert(spread.valid());
	assert(spread(t.mod));
}

unittest { // the pipeline's own schedule, spelled as a string, compiles a file
	// The evaluate-and-lower half of `doir.pipeline.canonicalizeSchedule` is
	// `fixedPoint(depthFirst(comptimeEvaluate))` then a strip then the fallback
	// schedule; writing it out here checks that the registry reaches the passes
	// a real compile needs, not just the easy ones.
	diagnostics().clear();
	auto mod = createModule();
	scope(exit) freeModule(mod);

	auto builders = createBuilderStack(mod);
	scope(exit) fp.dynarray.free(builders);
	assert(parseFile(mod, builders, "test.doir"));
	assert(!diagnostics().hasErrors());

	immutable root = runPipeline(mod, builders);
	assert(root != invalidEntity);
	assert(!diagnostics().hasErrors());

	// Everything `mizuSchedule` does, over the compiled module, as text. It is
	// idempotent, so running it again over a finished compile has to succeed.
	enum schedule = "sequential("
		~ "  depthFirst(pinRegisters),"
		~ "  breadthFirst(allocateRegisters),"
		~ "  depthFirst(pinRegisters),"
		~ "  breadthFirst(computeCompilerNamespace!false),"
		~ "  depthFirst(materializeImmediates),"
		~ "  depthFirst(materializeLabels),"
		~ "  breadthFirst(inlineFunctions),"
		~ "  breadthFirst(computeCompilerNamespace!true)"
		~ ")";
	auto system = parseSystem(schedule);
	scope(exit) freeSystem(system);
	assert(system.valid());
	assert(system(mod));
	assert(!diagnostics().hasErrors());
	diagnostics().clear();

	// That half is the one place with a pass the registry could not have reached
	// on its own - `comptimeEvaluate` takes the schedule it lowers each block
	// with as an argument - so check that its bound form is nameable.
	// Parsed, not run: re-evaluating an already-evaluated module is not the
	// same thing twice.
	enum opt = "sequential("
		~ "  fixedPoint(depthFirst(comptimeEvaluateVisitor)),"
		~ "  breadthFirst(stripFreestandingBlocks),"
		~ "  doir.pipeline.mizuSchedule"
		~ ")";
	auto optAsText = parseSystem(opt);
	scope(exit) freeSystem(optAsText);
	assert(optAsText.valid());
}

unittest { // `parallel` dispatches, and agrees with running in order
	auto t = makeTree();
	scope(exit) freeModule(t.mod);
	// A schedule string walks the canonical root, having no way to name an
	// entity, so point it at the fixture's.
	immutable previousRoot = newRoot;
	newRoot = t.root;
	scope(exit) newRoot = previousRoot;

	auto pool = bc.threadpool.create(4);
	scope(exit) bc.threadpool.free(pool);

	// Two walks of the same read-only pass over the same tree: nothing either
	// branch does depends on the other, which is the only kind of schedule
	// `parallel` is safe for, dispatched or not.
	enum schedule = "parallel(depthFirst(pinRegisters), breadthFirst(pinRegisters))";

	auto dispatched = parseSystem(schedule, pool);
	scope(exit) freeSystem(dispatched);
	assert(dispatched.valid());
	assert(dispatched(t.mod));

	// The same schedule without a pool runs its branches in order instead, and
	// has to reach the same answer - the property `ecrs.system.parallel`'s
	// single-worker fallback is built around.
	auto serial = parseSystem(schedule);
	scope(exit) freeSystem(serial);
	assert(serial.valid());
	assert(serial(t.mod));
}
