# DOIR3

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

