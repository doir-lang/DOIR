# DOIR

A `-betterC` D compiler prototype for the DOIR language, built on Mizu, libECRS
and libdiagnose.

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
  rule names there are the spec's.

Cite rule names when explaining behaviour. If the code contradicts the spec,
say which one you are treating as correct.

[grammar.peg](grammar.peg) is the grammar the parser is generated from; it and
the spec's grammar section must stay in step.

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

## Build / test

```sh
dub build --compiler=ldc2 --config=doir   # bin/doir <file.doir>
dub test  --compiler=ldc2                 # bin/doir-tests
tools/coverage.sh                         # per-module coverage
```

LDC only — Mizu overflows the stack under DMD (no TCO on the VM dispatch loop).
`mizu.doir` is generated; regenerate it after bumping Mizu rather than editing
it (tools/mizu_gen.d).
