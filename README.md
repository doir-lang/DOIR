# DOIR3

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

### Regenerating `mizu.doir`

`mizu.doir` binds every Mizu instruction at the DOIR level, and bakes in the
numeric instruction ids `mizu.lookup` assigns. Those ids are fixed at *compile*
time from Mizu's own module list, so the file has to be regenerated whenever the
Mizu dependency is bumped:

```sh
dub build --compiler=ldc2 --config=mizu-gen && ./bin/mizu-gen > mizu.doir
```

