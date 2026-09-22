# DOIR3

## The specification

[`doir.spec.typ`](doir.spec.typ) is the language reference, built with
[Typst](https://typst.app):

```sh
typst compile doir.spec.typ      # -> doir.spec.pdf
typst watch doir.spec.typ        # ... while editing
```

Part I states the language -- the seven assignment forms, types, comptime,
deduction, modules and the PEG grammar. Part II gives its formal semantics as
inference rules over the entity store, each marked with whether the compiler
implements it, and closes with the divergences between the spec, the standard
interface and this implementation. `standard.doir` carries the part of it you
need in order to read `standard.doir` as a header comment.

## Style

Types are plain data; everything that operates on them is a module-level free
function taking the data as its first parameter, the way
[libfp](https://github.com/doir-lang/libfp/tree/D) does it. UFCS means both
spellings work — `length(list)` and `list.length` are the same call — so the
call sites read like methods without the types carrying any.

What stays a member: operator overloads and constructors (`Lookup(e)`,
`InternedString`'s `opEquals`, `opIndex` on the owning lists), the
`static swapEntities`/`static finalize` hooks libECRS looks up by name on a
component type, and the `opCall`s that make a walker's `Bound` or a
`FixedPoint` callable as a libECRS system.

Two things to know when adding one of these:

- UFCS does not reach through a pointer. Components move, so passes hold them
  as `auto c = &getComponent!T(mod, e)` — call those as `length(*c)`, not
  `c.length`.
- A free function declared in a module *hides* every imported one of that
  name rather than overloading against it, and aliasing the import back in
  re-exports it and makes it ambiguous downstream. So a module that declares
  its own `free` names another module's as `doir.module_.free(map)`. Module
  teardown is `freeModule` for that reason — it is called from everywhere.

## Building (`-betterC` D)

The compiler is a [dub](https://dub.pm) package depending on the D branches of
[Mizu](https://github.com/doir-lang/Mizu/tree/D),
[libECRS](https://github.com/doir-lang/libECRS/tree/D) and
[libdiagnose](https://github.com/doir-lang/libdiagnose/tree/D).

Build with LDC — Mizu refuses to build under DMD, which performs no tail call
optimization and so overflows the stack on the VM's dispatch loop.

```sh
dub build --compiler=ldc2 --config=doir   # bin/doir <file.doir>
dub test  --compiler=ldc2                 # bin/doir-tests
```

`bin/doir <path>` compiles a `.doir` file, prints the resulting IR and writes
the Mizu binary to `res.bin`.

## Coverage

```sh
tools/coverage.sh        # per-module summary
tools/coverage.sh -v     # ... and every uncovered line
DC=dmd tools/coverage.sh # measure with DMD instead of the default LDC
```

`-cov` records its line counts through druntime, which `-betterC` does not
have, so the script builds the same sources and the same tests as ordinary
D — `tests/runner.d` supplies a druntime `main` when `DoirCoverage` is set,
and disables druntime's own test pass so the tests still run exactly once. It
asks `dub describe` where the sources, import paths, libraries and versions
are rather than repeating `dub.json`, and drops any dependency's `.lst` files
from the report so the numbers cover DOIR only.

### What the last percent is

Every reachable line is covered. The ~40 that are not are all one of three
things, and none of them can be reached by a test that lives to report it:

- **`panic` and its call sites.** `panic` prints and calls `abort()`; a test
  that reaches one takes the whole run down with it, and `-cov` writes its
  counts at druntime shutdown, which an aborting process never gets to. Most
  of these are `doir.verify`, whose checks are assertions about the compiler's
  own IR rather than about the program being compiled — so a test could only
  reach one by hand-building IR the compiler itself cannot produce.
- **The three lines next to one.** A `case` label, a `default` label and a
  `printf` that each sit directly in front of a `panic`.
- **`buildAssignment`'s `case ValueKind.none`.** `final switch` requires every
  enum member to have a case, and `assignment` only calls `buildAssignment`
  with `hasValue` false for that one — so the case exists to satisfy the
  language, not because anything reaches it.

### Regenerating `mizu.doir`

`mizu.doir` binds every Mizu instruction at the DOIR level, and bakes in the
numeric instruction ids `mizu.lookup` assigns. Those ids are fixed at *compile*
time from Mizu's own module list, so the file has to be regenerated whenever the
Mizu dependency is bumped:

```sh
dub build --compiler=ldc2 --config=mizu-gen && ./bin/mizu-gen > mizu.doir
```

