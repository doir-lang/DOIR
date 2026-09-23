# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

# DOIR

A `-betterC` D compiler prototype for the DOIR language, built on Mizu, libECRS
and libdiagnose. Every module is a port of a C++ predecessor and says so in its
doc comment — when a shape looks arbitrary, the original is usually the reason.

## Read the semantics before touching semantics

Any question about what the *language* means — what an assignment form does,
how names resolve, what a modifier does to the store, when a copy is implicit —
is answered by these two files, not by inference from the D sources:

- [doir.spec.typ](doir.spec.typ) — the language reference. Sections carry Typst
  labels; grep for the label rather than a line number, which drifts.
  `<part-one>` states the language: the seven assignment forms, types, comptime,
  deduction, modules, and the PEG grammar. `<part-two>` gives the formal
  semantics as inference rules over the entity store, each rule named
  (`M-Flag`, `R-Unqual`, `V-NoImplicitCopy`, …) and marked with whether the
  compiler implements it. Within it, `<identity>`, `<modifiers>`, `<copying>`,
  `<resolution>`, `<comptime>` and `<foreign>` are the sections rules most often
  refer back to. `<divergences>` records where the standard interface or this
  implementation departs from the spec — the spec is right and each departure is
  a defect, so check there before "fixing" a mismatch, and its Outstanding list
  is what is actually left to do.
- [standard.doir](standard.doir) — the standard interface, and the best worked
  example of idiomatic DOIR. Its header comment — everything above
  `std : namespace` — condenses the part of the semantics needed to read it; the
  rule names there are the spec's. It compiles clean — but not on its own: it
  assumes the assembler layer provides `u1`, `u8` and `pointer_sized`, so
  compile [test_standard.doir](test_standard.doir), which declares those and
  early_includes it. One line is commented out, and `<divergences>` says why.

Cite rule names when explaining behavior. If the code contradicts the spec,
say which one you are treating as correct.

[grammar.peg](grammar.peg) is the grammar the parser is generated from; it and
the spec's grammar section must stay in step. [parser.d](source/doir/parser.d)
is hand-written recursive descent whose rule names and order mirror it one for
one, so the two can be diffed.

## Architecture

**A module is an entity store, not a syntax tree.** [Module](source/doir/module_.d)
wraps a libECRS `Context`; a declaration is an entity carrying components
(`Name`, `TypeOf`, `Call`, `Block`, `Parent`, `Flags`, `Lookup`, …, all declared
at the top of [interface_.d](source/doir/interface_.d)). There is no AST — the
parser builds entities directly through `BlockBuilder`, and every pass reads and
edits the store. `Lookup` is the tagged union standing in for a reference that
has not been resolved yet.

**A pass is a visitor `bool(ref Module, EntityId)`; a schedule composes walkers.**
[doir.systems](source/doir/systems.d) supplies `depthFirst`, `breadthFirst`,
`sorted`, `fixedPoint` and `moduleSystem` on top of libECRS's `sequential` /
`parallel`. The visitor travels as a compile-time alias, not a function pointer
plus context — `-betterC` has no GC to hang a closure's capture off, and the
alias lets the walk inline. Returning `false` from a visitor stops the walk.

**The same schedule can arrive as a string.**
[doir.dynamic_systems](source/doir/dynamic_systems.d) parses
`"sequential(depthFirst(pinRegisters), …)"` at runtime into something the same
combinators accept. Registration is compile time: `passModules` is enumerated
with `__traits(allMembers)` and every pass-shaped symbol is instantiated into
all three walkers, so a new pass becomes spellable in a schedule string as soon
as it compiles. This is what `compiler.run_schedule` and
`compiler.override_fallback_schedule` execute.

**The pipeline is one schedule, and it lives in the library.**
[pipeline/package.d](source/doir/pipeline/package.d) is the single definition
both `main.d` and the tests drive. `runPipeline` is: `structure` verify →
`canonicalizeSchedule` → final `sort` → verify. `canonicalizeSchedule` splices
`early_include`s to a fixed point, resolves lookups, introduces type variables,
runs the interleaved deduction/comptime fixpoint, and then hands the module to
the *fallback schedule* — `mizuSchedule` unless the source overrode it, which
`mizu.doir` does. Read that file's comments before reordering anything; each
pass's position is argued there.

**`sort` is load-bearing.** [canon/sort.d](source/doir/pipeline/canon/sort.d)
renumbers every entity into post-order, so a block's children precede it and id
ranges can be walked directly. Phases that add entities are separated by sorts
for exactly that reason; a pass that splices declarations mid-schedule uses
`sorted!...` *without* the re-sort, because renumbering invalidates ids the
surrounding schedule is holding.

**Directory is not pass namespace.** The doc comments name the C++-era namespace
(`sema.`, `canonicalize.`, `opt.`), which often disagrees with where the file
landed — `canon/comptime.d` holds `sema.bubbleComptime`,
`canon/strip_freestanding_blocks.d` holds `opt.stripFreestandingBlocks`. Do not
infer which phase a pass runs in from its path; read the schedule.

**Comptime runs real Mizu.**
[opt/mizu/comptime_evaluate.d](source/doir/pipeline/opt/mizu/comptime_evaluate.d)
builds a small Mizu program for one compile-time call, runs it on the VM, and
the four instructions in [mizu/instructions.d](source/doir/mizu/instructions.d)
write the result back into the store. A block lowered for comptime is lowered by
the same fallback schedule the module will be.

**`panic` is not a diagnostic.** Diagnostics ([diagnostics.d](source/doir/diagnostics.d))
are about the program being compiled; `panic` replaces the C++'s uncaught
`throw std::runtime_error` and aborts. [verify.d](source/doir/verify.d) is
assertions about the compiler's own IR, so nearly all of it panics.

## Comments

Terse. The code is read by someone who wrote it — do not narrate what a line
does, restate a signature, or caption an obvious block. Comment only:

- why, when the why is not recoverable from the code (an ordering constraint, a
  workaround, a deliberate divergence from the spec),
- the rule name a piece of code implements, when it implements one,
- genuinely confusing machinery (register lifetimes, the UFCS/pointer and
  free-function-hiding traps in the README, anything `-betterC` forces).

Same for chat replies: answer, don't walk through the diff line by line.

## Style

See the Style section of [README.md](README.md) — types are plain data, free
functions take the data first, plus the two UFCS traps (no UFCS through
pointers; a local free function hides imported ones of the same name, hence
`freeModule`).

No RAII closers. A type whose only purpose is to undo something in its
destructor is not worth the declaration — say it with `scope(exit)` at the site
that needs it, where the undo is visible next to the do. Where the state is
private to another module, give it a `beginX`/`endX` pair and let the caller
pair them; `doir.systems`' lowering filter is the worked example. Nesting order
is unchanged either way: `scope(exit)` unwinds last-in-first-out, exactly as
destructors did.

## Build / test

```sh
dub build --compiler=ldc2 --config=doir   # bin/doir <file.doir>
dub test  --compiler=ldc2                 # bin/doir-tests
tools/coverage.sh                         # per-module coverage (-v: uncovered lines; DC=dmd to switch compiler)
```

LDC only — Mizu overflows the stack under DMD (no TCO on the VM dispatch loop).
`bin/doir <path>` compiles, prints the resulting IR, and writes the Mizu binary
to `res.bin`.

`mizu.doir` is generated, and bakes in the numeric instruction ids Mizu assigns
at *compile* time — regenerate it after bumping the Mizu dependency rather than
editing it:

```sh
dub build --compiler=ldc2 --config=mizu-gen && ./bin/mizu-gen > mizu.doir
```

### Tests

Unit tests live at the bottom of the module they cover, under a
`// Tests` banner. [tests/runner.d](tests/runner.d) walks a hardcoded `modules`
list with `__traits(getUnitTests)` — **a new module's tests do not run until it
is added to that list.** There is no filter flag; to narrow a run, trim that
array. Progress goes to unbuffered stderr, so a hang or abort still shows how
far the run got.

[tests/pipeline_helper.d](tests/pipeline_helper.d) has the fixtures:
`makeModuleWithBuiltins` for a module with the builtin block closed,
`makeOpenModule` for one left open the way the driver leaves it for
`parseSource`. Tests drive `doir.pipeline` itself rather than defining a
schedule, so they exercise the same compile the driver does.

The end-to-end tests in `pipeline/package.d` compile the repository's own
`.doir` files: `test.doir` (early_includes all of `mizu.doir` and then
`standard.mizu.doir`, runs a quoted block on the comptime VM, and calls
`std.add`, `std.if`, `std.while` and a hand-written label and jump — the one
program written *against* the standard interface rather than declaring it),
`test_string.doir` (nothing but `compiler.emit`, so the byte emiter has
something to emit), and `test_standard.doir` (the assembler layer
`standard.doir` assumes, plus an early_include of it — which is where every
`deduced` in the repository is).
