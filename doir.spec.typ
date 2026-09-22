#let accent = rgb("#0a5c66")
#let accent2 = rgb("#7a5a12")
#let danger = rgb("#9c2436")
#let muted = rgb("#5a6b71")
#let hair = rgb("#c9d4d7")
#let panel = rgb("#f4f7f8")

#set document(title: "The DOIR Specification")
#set page(
  paper: "a4",
  margin: (x: 2.4cm, y: 2.2cm),
  numbering: "1",
  number-align: center,
)
#set text(font: ("Libertinus Serif", "Linux Libertine"), size: 10.5pt, lang: "en")
#set par(justify: true, leading: 0.62em)
#show raw: set text(font: "DejaVu Sans Mono", size: 8.6pt)
#show raw.where(block: true): it => block(
  width: 100%, fill: panel, stroke: (left: 2pt + accent), inset: (x: 9pt, y: 7pt),
  radius: (right: 2pt), breakable: true, it,
)
#show link: set text(fill: accent)

#set heading(numbering: "1.1")
#show heading.where(level: 1): it => block(width: 100%, above: 1.9em, below: 0.9em)[
  #set text(size: 15pt, weight: "bold")
  #it
  #v(-0.45em)
  #line(length: 100%, stroke: 0.7pt + hair)
]
#show heading.where(level: 2): set text(size: 11.6pt, weight: "bold")
#show heading.where(level: 3): it => block(above: 1.3em, below: 0.6em)[
  #set text(size: 9pt, weight: "bold", fill: muted)
  #upper(it.body)
]

// ------------------------------------------------------------------
// Rule presentation
// ------------------------------------------------------------------

#let status(s) = {
  let (fill, label) = if s == "impl" { (accent, "implemented") }
    else if s == "spec" { (accent2, "spec only") }
    else if s == "broke" { (danger, "contradicted") }
    else { (muted, s) }
  box(inset: (x: 4pt, y: 1.5pt), radius: 1.5pt, fill: fill.lighten(85%))[
    #text(size: 6.8pt, weight: "bold", fill: fill.darken(10%), tracking: 0.4pt)[#upper(label)]
  ]
}

/// One semantic rule: a tag, a name, the formal statement, and its gloss.
#let rule(tag, title, st, formal, gloss, kind: "plain") = {
  let bar = if kind == "mut" { accent2 } else if kind == "bad" { danger } else { accent }
  block(width: 100%, above: 1.1em, below: 1.1em, breakable: false,
    stroke: (paint: hair, thickness: 0.6pt), radius: 2pt, inset: 0pt,
  )[
    #block(width: 100%, fill: bar.lighten(90%), inset: (x: 8pt, y: 4.5pt),
      stroke: (bottom: 0.6pt + hair))[
      #text(font: "DejaVu Sans Mono", size: 8pt, weight: "bold", fill: bar.darken(8%))[#tag]
      #h(6pt) #text(size: 8.4pt, fill: muted)[#title]
      #h(1fr) #status(st)
    ]
    #block(width: 100%, inset: (x: 8pt, y: 7pt))[#align(center)[#formal]]
    #block(width: 100%, inset: (x: 8pt, y: 6pt), stroke: (top: 0.6pt + hair))[
      #set text(size: 9.3pt)
      #gloss
    ]
  ]
}

#let note(title, body, kind: "plain") = {
  let c = if kind == "warn" { accent2 } else if kind == "stop" { danger } else { accent }
  block(width: 100%, above: 1em, below: 1em, fill: c.lighten(94%),
    stroke: (left: 2.5pt + c), inset: (x: 9pt, y: 7pt), radius: (right: 2pt))[
    #text(size: 7.4pt, weight: "bold", fill: c.darken(10%), tracking: 0.5pt)[#upper(title)]
    #v(-0.3em)
    #set text(size: 9.4pt)
    #body
  ]
}

// ===========================================================================

#align(center)[
  #v(1.2cm)
  #text(size: 24pt, weight: "bold")[The DOIR Specification]
  #v(0.25cm)
  #text(size: 11.5pt, fill: muted)[
    An IR where the module is an entity store, every line is a register,\
    and the operations on types edit the types you hand them.
  ]
  #v(0.5cm)
  #line(length: 38%, stroke: 0.7pt + hair)
  #v(0.3cm)
  #text(size: 9pt, fill: muted)[
    Part I states the language. Part II gives its formal semantics,\
    reconciled against `standard.doir` and the compiler in `source/doir/`.
  ]
  #v(1.1cm)
]

#outline(depth: 2, indent: auto)
#pagebreak()

= Part I -- The language <part-one>

Every line#footnote[The exception is @foreign, which is why the original of this
sentence carried an asterisk.] represents assignment to a virtual register, and
can take one of seven forms.

```doir
%1 : i32 = 5              // #1 Constant assignment (name : type = value)
%2 : block = {            // #2 Block assignment (%2 stores "quoted" information
	%1 : i32 = 6          //     about the contents of the block)
	_ : _ = yield(%1)     // #3 Function execution
}
%3 : alias = %2           // #4 Alias assignment (%3 is resolved to %2)
math : namespace = {      // #5 Namespace assignment (registers can be named,
	vec2 : type = {       //     not just numbered)
		x : f32           // #6 Type assignment
		y : f32           // #7 Undefined assignment
	}
}
```

`_` means two different things depending on where it appears: in a *name* it
takes the next numbered register, and in a *type* it requests inference.

Registers are all single static assignment, so there is no concept of `const`
in the language. Pointers can be marked immutable, which raises an error
diagnostic if a value is then stored through them.

== Source locations

An assignment may be followed by source information, written
`<"?filename"?:line_start(-line_end)?:column_start(-column_end)?>`.

```doir
%4 : f32 = 0.0 <"main.cpp":32:1-8>
%4again : f32 = 0.0 <main.cpp:32:0>
```

If the column is set to zero the length of the entire line is computed. It is an
error for `line_start` to differ from `line_end` in that case.

Several assignments may share a line when separated with a semicolon.

== Calls take registers

Functions can only take register names. Constants must be stored in a register
first, so `add(5, 6)` is invalid, and a block must be named before it can be
passed:

```doir
%5 : i32 = execute({
	%1 : i32 = 6
	_ : _ = yield(%1)     // INVALID! -- execute needs a register, not a literal
})
%6 : i32 = add(%1, %5)
```

Types can be used as functions, with a parameter for each of their fields.
Namespaces prepend their name to all registers inside of them; the mangling
rules depend on the currently loaded mangler.

```doir
vector : math.vec2 = math.vec2(%4, %4)
```

== Functions

Functions are created in the same way as a block, but their type is
`(args...) -> return`. Omitting the return implies `void`. A function must end
with a call to a terminator such as `return` or `halt`, and may capture
registers in its parent scope.

```doir
pchar : type = type.pointer(i8)
ppchar : type = type.pointer(pchar)
%7 : (_ : i32, _ : ppchar) = {
	_ : _ = printf("%g", %6)
	_ : _ = return()
}
main : alias = %7
```

Functions can be anonymous, as `%7` is, or given names; an anonymous function
can have a name aliased to it later.

=== Control flow

Control flow is done via functions.

```doir
%8 : i1 = true
%9 : block = {            // if(condition, true block, false block)
	%1 : f32 = 5.0 _ : _ = yield(%1)
}
%10 : block = { _ : _ = yield(%4) }
%11 : f32 = if(%8, %9, %10)
```

=== Inlining, flattening and tail calls

```doir
%12 : f32 = inline add(%4, %4)
inline_add_t : type = function.forcibly_inline((i32, i32) -> i32)
auto_inlined_add : inline_add_t = { ... }
```

When a function is inlined its code lands in a new block. If that block is
undesirable the function can instead be flattened:

```doir
%12alt : f32 = flatten add(%4, %4)
flatten_add_t : type = function.always_flatten((i32, i32) -> i32)
```

A call can require tail-call optimization instead. Functions are tail-call
optimized automatically whenever they can be; the annotation only throws an
error diagnostic when this particular call cannot be.

```doir
%13 : f32 = tail add(%4, %4)
```

=== ABI names

```doir
%14 : byte_pointer = "some_mangled_add\0"
_ : _ = function.abi_rename(add, %14)
```

== Compile time

Function parameters can be marked comptime. They are not present in the ABI of
the resulting function, and their names may be mangled based on the currently
loaded mangler. Some types, such as `type` and `block`, are implicitly comptime.

```doir
comp_i32 : type = type.comptime(i32)
comp_pow : (mantissa : comp_i32, base : i32) = {
	pi32 : type = type.pointer(i32)
	x : pi32 = stack.allocate(i32)     // a pointer to stack memory
	%1 : i32 = 0
	%2 : i32 = pointer.load(x)         // values can be loaded from pointers
	%3 : i32 = subtract(%2, %1)
	%4 : i32 = pointer.store(x, %3)    // NOTE: %3 == %4
	// Registers are all single static assignment, so there is no `const`.
	// Pointers can be marked immutable, which makes a store an error.
	const_pi32 : type = pointer.immutable(pi32)
	%5 : const_pi32 = cast(x)
	%6 : void = pointer.store(%5, %3)  // Error!

	_ : _ = return()
}
```

```doir
my_add: (T : type, a : T, b : T) -> T = { ... }
```

== Deduction

Types don't have to be explicitly given when calling a function; they can be
deduced. The return type can be deduced too.

```doir
my_promote: (Tret : deduced type, T : deduced type, value : T) -> Tret = { ... }
%12 : i32 = my_promote(%4)   // Tret = i32, T = f32
```

`Tret` comes from the declared type of the register being assigned and `T` from
the argument, so deduction runs in both directions.

== Structural types and uniqueness

DOIR types are structural: if they have the same layout they will implicitly
convert. This can be disabled by making a unique type.

```doir
list : (T : type) -> type = {
	pself : type = type.pointer(type.self)  // type.self refers to the current type
	out : _ = type {                        // (P.S. How am I gonna implement this magic?)
		value : T
		next : pself
	}
	_ : _ = return(out)
}
int_list : type = list(i32)
%13 : _ = bss.allocate(int_list)
unique_int_list : type = type.unique(int_list)
%14 : int_list = pointer.load(%13)         // Perfectly fine
%15 : unique_int_list = pointer.load(%13)  // Error!
%16 : unique_int_list = cast(%14)          // Perfectly fine
```

Uniqueness blocks implicit conversion, not explicit casting.

== Modules

Assignments can be imported from other files. By default, if a symbol already
exists it won't be imported -- so an import at the end of a file will override
any imported symbols with those already in the file, while an import at the top
of a file will cause errors if symbols conflict. If an import is inside a
namespace all of its symbols will also be in that namespace.

```doir
path : null_terminated_byte_pointer = "path/to/file.doir\0"
_ : _ = import(path)
C : namespace = {
	stdint : null_terminated_byte_pointer = "path/to/stdint.doir\0"
	_ : _ = import(stdint)
}
```

By default an assignment is internal -- not visible when imported. To make it
visible it has to be exported.

```doir
%16272 : (%16273: deduced type, %16274: %16273, %16275: %16273)  // some obfuscated function
export my_library_add : alias = %16272
```

An entire namespace can be exported at once; everything inside it is implicitly
exported.

```doir
export print : namespace = {
	number : (value: i32) = { /*...*/ }
	string : (value: null_terminated_byte_pointer) = { /*...*/ }
}
```

== Other languages <foreign>

DOIR also supports changing to another available language. That language is
parsed inline, contributing its IR to that of the surrounding code -- so there
is no boundary object and no marshalling, just more entities in the same module.

```doir
language "C" {   // assuming a C language doir implementation can be found
	int main() {
		printf("Hello World\n");
	}
}
```

== Grammar

TitleCase productions need whitespace handling (`_` or `wsc`) after them when
they are used; snake-case productions handle whitespace themselves.

```peg
program <- _ assignment* !. # `!.` indicates end of input
assignment <- change_language / (<'export'>_)? Identifier _ ':'_ Type wsc (_ '='_ assignment_value)? (SourceInfo wsc)? Terminator _
assignment_value <- Constant wsc / Block wsc / function_call / Identifier wsc / Type wsc

change_language <- 'language'_ '"' < StringChar* > '"'_ matching_braces _
matching_braces <- '{' enforested_content* '}'
enforested_content <- matching_braces / [^{}]

deducible_type <- ('deduced'_)? Type _
parameter <- Identifier _ ':'_ deducible_type ('='_ Constant _)?
# `-> Type` is optional; omitting it means the function returns `void`.
FunctionType <- '('_ (parameter (','_ parameter)*)? ')' (_ <'->'>_ Type)?
Type <- FunctionType / Identifier

Block <- '{'_ assignment* '}'
function_call <- (<'flatten' | 'inline' | 'tail'>_)? Identifier _ '('_ (Identifier _ (','_ Identifier _)*)? ')'wsc

Terminator <- (';' | '\n' | '\r\n' | '\r') / !. # newline, semicolon, or end of input
Identifier <- "%" ('"' < StringChar* > '"') / !Keywords < ([%]/UnicodeIdentifierStart)([.]/UnicodeIdentifierContinue)* >
Keywords <- ('deduced' | 'export' | 'flatten' | 'inline' | 'language' | 'tail')_
SourceInfo <- ('<"' < (!'"' .)* > '":' / '<' < (!':' .)* > ':') < IntegerConstant > (<'-' IntegerConstant >)? ':' < IntegerConstant > (<'-' IntegerConstant > )? '>'

Constant <- < FloatConstant > / < IntegerConstant > / ('"' < StringChar* > '"') / ('\'' < StringChar > '\'')
IntegerConstant <- ('0x' HexDigit+) / ('0b' [01]*) / ('0' [0-7]*) / ([1-9][0-9]*)
# A FloatConstant must carry a '.' or an exponent marker; anything else is an
# IntegerConstant. The exponent's digits are optional, so a marker with nothing
# behind it (`1e`, `0x1.8p`) is part of the number and contributes nothing.
FloatConstant <- ('0x' (HexDigit* '.' HexDigit+ / HexDigit+ '.' HexDigit*) HexExponent? / '0x' HexDigit+ HexExponent)
	/ (([0-9]* '.' [0-9]+ / [0-9]+ '.' [0-9]*) DecExponent? / [0-9]+ DecExponent)
HexExponent <- [pP][+\-]? [0-9]*
DecExponent <- 'e'i[+\-]? [0-9]*
StringChar <- (!['"\n\\] .) / ('\\' ['\"?\\%abfnrtv]) / ('\\' [0-7]+) / ('\\x' HexDigit+) / ('\\u' HexDigit HexDigit HexDigit HexDigit) / ('\\U' HexDigit HexDigit HexDigit HexDigit HexDigit HexDigit HexDigit HexDigit)
HexDigit <- [a-f0-9]i

_ <- ([ \t\n\v\f\r...] / LongComment / LineComment)*
wsc <- ([ \t\v\f...] / LongComment / LineComment)*
LongComment <- '/*' (!'*/'.)* '*/'
LineComment <- ('//' | '#') (!'\n' .)*
```

The character classes for `_`, `wsc`, `UnicodeIdentifierStart` and
`UnicodeIdentifierContinue` are elided above; `grammar.peg` carries them in
full, along with the `RawString` production the implementation added.

#pagebreak()

= Part II -- Formal semantics <part-two>

DOIR has no syntax tree. A module is an entity-component store, every line of
source binds a virtual register in static single-assignment form, and every
construct denotes a *transformation of that store*. That shapes everything
below, most of all @modifiers, where applying `type.pack` to a type does not
compute a new type but edits the one you named.

#note("Three documents, one language")[
  Part I is the design. `standard.doir` is the standard interface written
  against it. `source/doir/` is the compiler, which implements some of both.
  Where they disagree the disagreement is itself the finding, and @divergences
  collects them.
]

#note("Notation")[
  $e$, $t$, $f$, $B$, $N$ range over entities; $n$ over names; $mu$ over
  modifiers. $e : C$ means "$e$ carries component $C$", and $C(e)$ is its value.
  $Phi(e)$ is $e$'s flag set, $alpha$ alias resolution, $sigma$ the scope chain.
  $tack.r$ is entailment, $⇓$ "resolves to", $⇝$ a store transition, $bot$
  undefined.
]

Each rule is marked #status("impl") where the compiler behaves this way,
#status("spec") where Part I or `standard.doir` intends it but nothing
implements it, and #status("broke") where the sources disagree.

== The store, and SSA

#rule("SSA", "Every line is a register", "impl",
  $ "each declaration binds one virtual register, assigned" bold("exactly once") ", never reassigned" $,
)[
  Part I opens with it, and settles it: "registers are all single static
  assignment, thus there is no concept of `const` in the language". This is why
  `const` is absent, why `pointer.immutable` exists, and why naming a register
  is not copying it (@copying). Immutability is not a modifier you apply to
  values -- it is what a value already is. Only memory reached through a pointer
  can change, so only pointers need a way to forbid it.
]

A module is a pair $M = ⟨E, C⟩$ with $E subset.eq_"fin" NN$ a
finite set of entity identifiers and $C$ a family of partial maps
$C : E harpoon.rt V_C$. Entities have no intrinsic structure; an entity *is*
whichever components are defined on it.

#figure(
  table(
    columns: (auto, auto, 1fr),
    stroke: none,
    align: (left, left, left),
    inset: (x: 5pt, y: 3.6pt),
    table.hline(stroke: 0.6pt + hair),
    table.header(
      [*Component*], [*Codomain*], [*Meaning*],
    ),
    table.hline(stroke: 0.6pt + hair),
    [`Name`], [interned string], [The source-level name of a declaration.],
    [`Parent`], [$E$], [The block that lists this entity.],
    [`Block`], [$E^*$], [An ordered list of child entities.],
    [`TypeOf`], [$E$], [The declared type of a value.],
    [`TypeDefinition`], [$NN^3$], [$⟨"size", "alignment", "unique"⟩$ in bits; the third is a discriminator (@identity).],
    [`Alias`], [$E$], [A second name for another entity.],
    [`Pointer`], [$E times NN$], [$⟨"target", "size"⟩$; size $= 0$ is a pointer, size $> 0$ an array.],
    [`FunctionInputs`], [$E^*$], [Parameter types of a function type, or arguments of a call.],
    [`FunctionReturnType`], [$E$], [A function's result type.],
    [`FunctionParameter`], [$NN$], [Marks an entity as parameter $i$ of its function.],
    [`Call`], [$E$], [The callee; arguments live in `FunctionInputs`.],
    [`Number`, `DString`], [$RR$, string], [Literal values.],
    [`SourceLocation`], [file $times$ span], [Optional; written after an assignment.],
    [`Flags`], [$cal(P)(F)$], [Valueless, Namespace, Export, Comptime, AlwaysComptime, NoComptime, Constant, Union, Pure, Inline, Flatten, Tail.],
    table.hline(stroke: 0.6pt + hair),
  ),
  caption: [The component types an entity is built out of.],
)

A declaration is an entity, not a term, so there is exactly one of it. Two names
for one declaration are the *same entity*. Every identity question below reduces
to entity identity or to the layout comparison of @identity.

== Well-formedness

Violating one of these aborts the compiler rather than producing a diagnostic.

#rule("val", "Value components", "impl",
  $ "val"(e) = {"Valueless" in Phi(e)} union {e : "Number"} union {e : "DString"} \
   union {e : "Call"} union {e : "FunctionReturnType"} union {e : "Block"} $,
)[
  The components that count as giving an entity a value.
]

#rule("WF-Val", "Exactly one value", "impl",
  $ (e : "TypeOf") / (|"val"(e)| = 1 or "val"(e) subset.eq {"FunctionReturnType", "Block", "Valueless"}) $,
)[
  Every typed declaration has *exactly one* value: a number, a string, a call, a
  block, or nothing at all (form 7). Functions are the exception, and admit two
  shapes: a function *with* a body carries its return type and that body, and a
  function *declared but not defined* carries the return type
  `sema.materializeFunctionTypesAndParameters` copied off its type plus the
  `Valueless` the parser set for the missing `=`. Every declaration in
  `standard.doir` has that second shape.
]

#rule("WF-Arg", "Arguments are registers", "impl",
  $ "every argument of a call is an" bold("Identifier") "; literals and nested expressions are not arguments" $,
)[
  Constants must be stored in a register first, so `add(5, 6)` is invalid. This
  is what makes the IR flat: *there are no subexpressions*, so every intermediate
  value is named and every name is a register. It is also why a block passed to
  `if` or `execute` must be declared first.
]

#rule("WF-Term", "Functions end in a terminator", "spec",
  $ (f "a function with body" B) / ("last"("Block"(B)) "is a call to a terminator" in {"return", "yield", "halt", ...}) $,
)[
  Blocks yield, functions return. Neither `return` nor `yield` was declared
  anywhere in `standard.doir`; both are now.
]

#rule("WF-Par", "Parent/child agreement", "impl",
  $ (e : "Parent" quad B = "Parent"(e)) / (e in "Block"(B) and "Block"(B) "is duplicate-free") $,
)[
  Parenthood is a two-way link that must agree in both directions; a block lists
  each child once.
]

#rule("WF-Kind", "Kind exclusivity", "impl",
  $ "each" e "is exactly one of" \
   "value" (e : "TypeOf") quad | quad "type" (e : "TypeDefinition") \
   "namespace" ("Namespace" in Phi(e)) quad | quad "alias" (e : "Alias") $,
)[
  The four kinds are mutually exclusive, each forbidding the others'
  components. The keywords `type`, `alias` and `namespace` are reserved and may
  not be redeclared outside the builtin block -- which is load-bearing, not
  cosmetic: a namespace named `type` would capture the declared type `: type` of
  every declaration around it by @resolution.
]

== Name resolution <resolution>

Resolution is a total function from a name and a reference site to an entity or
$bot$. Let $"children"(B) = "Block"(B)$. The *scope chain*
$sigma(e) = ⟨B_0, B_1, ...⟩$ has $B_0$ the block containing $e$ and
$B_(i+1) = "Parent"(B_i)$, terminating at the root.

#rule("findIn / nsIn", "Member and segment lookup", "impl",
  $ "findIn"(B, n) = "first" e in "children"(B) "with" "Name"(e) = n \
   "nsIn"(B, s) = alpha(e) "if additionally" "Namespace" in Phi(alpha(e)) $,
)[
  A path segment resolves *through aliases*, so `ns2 : alias = ns` makes
  `ns2.member` legal. The final name in a path does not.
]

#rule("R-Unqual", "Unqualified name", "impl",
  $ (B_i in sigma(e) quad "findIn"(B_i, n) = e' quad forall j < i . "findIn"(B_j, n) = bot) / (e tack.r n ⇓ e') $,
)[
  A bare name is sought in the block containing the reference, then its parent,
  out to the root. The innermost block declaring it wins.
]

#rule("R-Qual", "Dotted path", "impl",
  $ (B_i in sigma(e) quad "nsIn"(B_i, s_1) = N_1 quad forall j < i . "nsIn"(B_j, s_1) = bot \
    N_(t+1) = "nsIn"(N_t, s_(t+1)) quad "findIn"(N_k, m) = e')
   / (e tack.r s_1. dots.c .s_k .m ⇓ e') $,
)[
  *Only the first segment walks the scope chain.* Once $s_1$ is found, later
  segments and the final name are looked up exactly, in that namespace only. If
  it lacks the rest of the path, resolution *fails outright* -- there is no
  backtracking to an outer namespace of the same name. This is why the `meta`
  namespace of `standard.doir` must spell out `std.types.comptime`: written
  inside `meta`, a bare `types.` finds `meta.types`, whose `comptime` takes an
  `entity` rather than a `type`.
]

#rule("R-Order", "Order independence", "impl",
  $ e tack.r n ⇓ e' "is independent of the positions of" e "and" e' "within" "children"(B) $,
)[
  `findIn` scans a block's entire child list, so *declarations within a block are
  mutually visible regardless of order*; forward and mutually recursive
  references are legal. Note the contrast with @comptime's C-Order: *names are
  order-free, effects are not.*
]

#rule("R-Mangle", "Namespaces are a name prefix", "impl",
  $ "for each" e "in the subtree of namespace" N: quad "Name"(e) := "Name"(N) dot.c "Name"(e) $,
)[
  A namespace is a scope at resolution time and a *name prefix* at emission
  time; it has no runtime representation of its own.
]

== Type identity <identity>

#rule("A-Res", "Alias resolution", "impl",
  $ alpha(e) = alpha("Alias"(e)) "if" e : "Alias"; quad alpha(e) = e "otherwise" $,
)[
  Follow the alias link until it stops. *Side condition:* the alias graph must
  be acyclic -- `x : alias = x` has no denotation and diverges rather than
  erroring.
]

#rule("S-Struct", "Types are structural", "spec",
  $ ("layout"(T_1) = "layout"(T_2) quad "unique"(T_1) = "unique"(T_2) = 0) / (T_1 tilde.equiv T_2 quad "(implicitly inter-convertible)") $,
)[
  Types are structural: same layout implies implicit conversion, and `unique` is
  the opt-out. This is the normative rule, and it is what makes `type.unique` a
  meaningful operation rather than a curiosity. A type's identity is its layout
  together with its discriminator, and nothing else -- not the entity that
  happens to carry it, and not the name it was declared under.
]

#rule("A-Ident", "The compiler compares entities instead", "broke",
  $ "as implemented:" quad T_1 equiv T_2 space <==> space alpha(T_1) = alpha(T_2) $,
  kind: "bad",
)[
  The compiler compares types by entity, and every `compiler.base_type` call
  draws a fresh discriminator from a per-$⟨"size", "alignment"⟩$ counter, so two
  independently declared 64-bit types come out *distinct* -- precisely what
  S-Struct forbids. *This is a defect, not a design alternative:* the `unique`
  field is doing nominal work when it exists to be the opt-out from structural
  comparison.

  The fix has two halves. `nextUnique` must stop handing out a discriminator per
  `base_type` call and leave it $0$, reserving non-zero values for `type.unique`
  (which is how M-Unique is already written); and type comparison must compare
  $⟨"size", "alignment", "unique"⟩$ rather than $alpha$-equality of entities.
  Until then `equiv` is strictly finer than $tilde.equiv$, so every type is its
  own -- which no program notices yet only because nothing implements implicit
  conversion either.
]

#rule("A-Transparent", "Aliases are not objects", "impl",
  $ e : "Alias" ==> e "contributes no storage, no layout, and no distinct type" $,
)[
  `null_terminated_byte_pointer : alias = byte_pointer` is a comment with a name
  attached; nothing checks it, and under S-Struct nothing would check it even if
  it were a separate type of the same layout. Making it real is what
  `type.unique` is for.
]

== The modifier discipline <modifiers>

A modifier does not compute a type from a type; it *edits* a type and hands back
a name for the type it just edited.

#rule("M-Flag", "Modifier application, in place", "impl",
  $ (e tack.r a ⇓ t quad t : "TypeDefinition" quad mu "a flag modifier with flag" f_mu)
   / (⟨c : "type" = mu(a)⟩ ⇝ Phi(t) := Phi(t) union {f_mu}; quad "Alias"(c) := t) $,
  kind: "mut",
)[
  Applying a modifier *mutates the argument type itself* and collapses the call
  site into an alias to that same, now-modified type, dropping the call's own
  `Call`, `TypeOf` and `FunctionInputs`. No entity is allocated; afterwards $c$
  and $t$ are two names for one type. This is not a proposal -- it is what the
  compiler already does for `always_inline` and `always_comptime`.

  The idiom this produces, used throughout `standard.doir` and `mizu.doir`, is to
  declare a type once under its real name and modify it in place on the next
  line, discarding the alias:

  #raw(block: true, lang: "doir",
    "modifier_function : type = (in: type) -> type\n_ : type = comptime(modifier_function)")
]

#figure(
  table(
    columns: (auto, 1fr, auto),
    stroke: none,
    inset: (x: 5pt, y: 3.6pt),
    table.hline(stroke: 0.6pt + hair),
    table.header([*Modifier*], [*Effect on the argument*], [*Status*]),
    table.hline(stroke: 0.6pt + hair),
    [`type.comptime`], [$Phi := Phi union {"AlwaysComptime"}$], [#status("impl")],
    [`type.union`], [$Phi := Phi union {"Union"}$ -- the aggregate's fields overlap], [#status("spec")],
    [`type.pack`], [Recomputes size/alignment to the tightest layout], [#status("spec")],
    [`function.forcibly_inline`], [$Phi := Phi union {"Inline"}$], [#status("impl")],
    [`function.always_flatten`], [$Phi := Phi union {"Flatten"}$], [#status("spec")],
    [`pointer.immutable`], [$Phi := Phi union {"Constant"}$ -- stores through it become errors], [#status("spec")],
    [`function.abi_rename`], [Rewrites the emitted symbol name], [#status("spec")],
    [`type.set_attribute_id`], [Records which component slot the type occupies], [#status("spec")],
    table.hline(stroke: 0.6pt + hair),
  ),
  caption: [The flag modifiers, and how far each is implemented.],
)

#note("Not every operation in the type namespace is a modifier", kind: "stop")[
  `standard.doir` originally typed `pointer` as `modifier_function`, but it
  cannot mutate in place: a type cannot be edited into a pointer *to itself*.
  The compiler agrees -- `compiler.pointer` builds a fresh `Pointer` at the call
  site and leaves its argument untouched, while `always_comptime` mutates and
  aliases. The two classes now have distinct spellings, `modifier_function` and
  `constructor_function`, so a declaration's type says whether calling it will
  edit what you hand it.
]

#rule("M-Ctor", "Constructor (pointer, array)", "impl",
  $ (e tack.r a ⇓ t quad t : "TypeDefinition" quad c "fresh")
   / ("pointer"(a) ⇝ "Pointer"(c) := ⟨t, 0⟩ quad quad "array"(a, n) ⇝ "Pointer"(c) := ⟨t, n⟩) $,
)[
  A constructor *allocates* and leaves its argument alone. An array is a pointer
  that knows its length -- one component, discriminated by a non-zero size.
]

=== Properties of the discipline

#rule("P1", "Idempotence", "impl",
  $ mu(mu(t)) = mu(t) quad "for every flag modifier" mu $,
  kind: "mut",
)[
  Flag setting is set union, so applying a modifier twice is applying it once.
  Marking an already-comptime type comptime is a no-op, not an error -- where a
  generative reading would produce two distinct types.
]

#rule("P2", "Modifiers take effect from where they are written", "impl",
  $ "after" ⟨c : "type" = mu(a)⟩ "at lexical position" k, quad f_mu in Phi(t)
   "for every reference to" t "at a position" > k $,
  kind: "mut",
)[
  A modifier is not scoped to a block, but it is not retroactive either: it
  applies from its own position onward, in lexical order (C-Order). Packing a
  type on line 200 leaves line 5 alone and changes every use below it. So the
  unit a modifier attaches to is *the rest of the program*, not the enclosing
  block and not the whole module -- which is why the idiom is to declare a type
  and modify it on the line immediately after, before anything can refer to the
  unmodified form.
]

#rule("P3", "Aliases transmit modification", "impl",
  $ mu(a) "where" alpha(a) = t quad ⇝ quad "modifies" t ", not" a $,
  kind: "mut",
)[
  Modifiers act through $alpha$. Since `byte` aliases `u8`, `type.pack(byte)`
  packs `u8` itself, and so changes `index`, `byte_pointer`, and everything else
  reached through it. *An alias offers no insulation.* The single exception is
  M-Unique, and that exception is what makes the escape hatch work.
]

#rule("P4", "Commutativity", "impl",
  $ mu_1 compose mu_2 = mu_2 compose mu_1 "when both are flag modifiers; not guaranteed when both alter layout" $,
  kind: "mut",
)[
  Flag modifiers commute because set union does. `pack` and `union` both rewrite
  layout and need a defined order -- packing a union is not unioning a packed
  aggregate -- and C-Order supplies it: lexical position decides, so the one
  written first applies first. The order is part of the language, not an
  artefact of how the passes happen to walk the store.
]

#rule("P5", "Modifiers are impure", "spec",
  $ "Pure" in.not Phi(mu) quad "for every modifier" mu $,
  kind: "mut",
)[
  A modifier's whole content is its effect on the store, so `Pure` must never be
  set on one. It would license eliding a duplicate call -- harmless under P1 --
  but equally license reordering against a layout modifier, which P4 forbids.
]

== Copy, move, unique <copying>

If modifiers mutate, the language needs a way to say "give me my own one first".
There is one per level, and the value-level one is already enforced.

#figure(
  table(
    columns: (auto, auto, auto),
    stroke: none,
    inset: (x: 6pt, y: 4pt),
    table.hline(stroke: 0.6pt + hair),
    table.header([], [*Share the object*], [*Get a new object*]),
    table.hline(stroke: 0.6pt + hair),
    [*Values* (SSA registers)], [`x : alias = v`], [`copy(T, v)` / `move(T, v)`],
    [*Types*], [`T2 : alias = T`], [`type.unique(T2)`],
    table.hline(stroke: 0.6pt + hair),
  ),
  caption: [Sharing is spelled `alias` at both levels; duplication is spelled out.],
)

#rule("V-NoImplicitCopy", "Naming is not copying", "impl",
  $ (T equiv.not "alias" quad v "an identifier") / (⟨x : T = v⟩ ⇝ "ill-formed (E010)") $,
  kind: "bad",
)[
  Writing an existing name on the right of `=` is *rejected* unless the declared
  type is `alias`; you must say `copy` or `move`. This follows directly from SSA:
  a register is written once, so a second name for it is either an alias or a new
  register, never an assignment. The parser enforces it today.
]

#rule("V-Copy / V-Move", "Value duplication", "spec",
  $ "copy"(T, v) ⇝ "fresh register, same value," v "live" \
   "move"(T, v) ⇝ "fresh register, same value," v "invalidated" $,
)[
  `copy` duplicates storage, never identity -- the type is shared, only the
  register is new. `move` does the same and *invalidates its source*: reading
  $v$ after a move is ill-formed.

  That invalidation is normative but currently unenforced, and currently
  unobservable: the prototype treats every type as POD, and for a POD type a
  move and a copy produce the same bytes and leave the same source register
  readable. So `move` is spelled as an inlined `copy` in `standard.doir` and
  nothing yet distinguishes them. The distinction begins to matter the moment a
  type owns something -- which is also when the liveness analysis that enforces
  it has to exist.

  Both are *overload sets* (T-Overload), not single functions. The members in
  `standard.doir` are the defaults every POD type uses; a type that owns
  something attaches its own with `function.add_overload`, and the call site
  selects by argument type. This is where a copy constructor lives, and it is
  why `copy` and `move` had to be ordinary declarations rather than builtins:
  a builtin could not be extended.
]

#rule("M-Unique", "Unique, in place", "spec",
  $ (e tack.r a ⇓ t quad u = alpha(t) quad "layout"(u) = ⟨s, l⟩)
   / ("unique"(a) ⇝ "Alias"(t) := bot; quad "TypeDefinition"(t) := ⟨s, l, nu⟩ "with" nu "fresh, non-zero") $,
  kind: "mut",
)[
  *`unique` is the one modifier that does not act through $alpha$.* It acts on
  the entity you named: it severs that entity's alias link and gives it a type
  definition of its own -- the same layout as its former target, plus a fresh
  non-zero discriminator that takes it out of S-Struct's implicit-conversion
  relation. If it followed $alpha$ like every other modifier,
  `type.unique(byte)` would mutate `u8` itself and make the whole program's byte
  type unique, inverting its purpose.
]

#note("The generative and in-place readings agree")[
  Part I's `unique` is generative: `int_list` survives
  `unique_int_list : type = type.unique(int_list)` unchanged. The in-place
  discipline reproduces that behaviour exactly; it only changes the spelling,
  because the new type must be *named* before it can be modified:

  #raw(block: true, lang: "doir",
    "unique_int_list : alias = int_list\n_ : type = type.unique(unique_int_list)")

  `int_list` is untouched, so `%14` still loads fine; `unique_int_list` now
  carries a non-zero discriminator, so `%15` is still an error; and `cast` still
  bridges them explicitly at `%16`. It costs one extra line and buys P1--P5
  everywhere else.
]

== Types and formers

#figure(
  table(
    columns: (auto, 1fr, auto),
    stroke: none,
    inset: (x: 5pt, y: 3.6pt),
    table.hline(stroke: 0.6pt + hair),
    table.header([*Former*], [*Representation*], [*Class*]),
    table.hline(stroke: 0.6pt + hair),
    [`compiler.base_type(s, a)`], [Fresh `TypeDefinition`], [generative],
    [`type.pointer(T)`], [`Pointer` $⟨T, 0⟩$], [constructor],
    [`type.array(T, n)`], [`Pointer` $⟨T, n⟩$, $n > 0$], [constructor],
    [`(a: A, b: B) -> R`], [`FunctionInputs` + `FunctionReturnType` + names], [generative],
    [`type = { f : T ... }`], [`TypeDefinition` + `Block`; fields are form-7 declarations], [generative],
    [`type.union(T)`], [Union flag on an aggregate], [modifier],
    table.hline(stroke: 0.6pt + hair),
  ),
  caption: [Type formers, and whether each allocates.],
)

#rule("T-Construct", "Types are callable", "broke",
  $ (T : "TypeDefinition" quad "Block"(T) = ⟨f_1, ..., f_n⟩ quad "typeof"(a_i) tilde.equiv "typeof"(f_i))
   / (T(a_1, ..., a_n) : T) $,
  kind: "bad",
)[
  Part I says types can be used as functions with a parameter for each of their
  fields. *The compiler rejects this today*: a `TypeDefinition` has no `TypeOf`,
  so arity checking reports "is not a function and cannot be called". Aggregate
  construction has no other spelling in the language, so this is a gap rather
  than a preference.
]

#rule("T-Self", "The self type", "spec",
  $ (t = "the type currently being constructed at the point of reference") / (e tack.r "type.self" ⇓ t) $,
)[
  The only name whose meaning is not a function of resolution alone. Part I's
  example is a recursive list built inside a type-returning function, where
  `type.self` is referenced *before* the type it denotes has been declared. The
  author's own parenthetical -- "How am I gonna implement this magic?" -- is the
  honest status. A rule of "innermost enclosing type definition" is not enough,
  because at the point of use there is no enclosing type definition yet: `self`
  must denote the type the enclosing function is in the process of returning.
  That needs either a two-pass elaboration of type-returning functions or an
  explicit self-binder.
]

#rule("T-Overload", "Overload sets", "spec",
  $ ("add_overload"(S, f) ⇝ "typeof"(S) := "flatten"("typeof"(S) union "typeof"(f)))
   / ("call"(S, "args") "selects the unique" g in S "whose inputs unify with typeof(args)") $,
  kind: "mut",
)[
  A flattened union of function types. Ambiguity or no match is ill-formed, and
  a function declared alone is already a one-member set -- there is no separate
  act of creating one.

  `add_overload` is a modifier (M-Flag): it edits the set it is handed rather
  than returning a new one, so a set is an *extension point* that later code
  grows. By C-Order that growth is lexically ordered, which means a call
  resolves against exactly the members added above it. Two calls written either
  side of an `add_overload` can therefore select different functions, and that
  is the intended mechanism rather than an accident -- it is how a type
  declared later in a file attaches its own behaviour to a name declared
  earlier.
]

== Comptime <comptime>

*Comptime* means "this value is known now"; *AlwaysComptime* means "every value
of this type is". The `type` and `block` builtins carry both.

#rule("C-Call", "Bubbling through calls", "impl",
  $ (e : "Call" quad f = alpha("Call"(e)) quad "ft" = alpha("TypeOf"(f)) \
    (forall a in "FunctionInputs"(e) . "Comptime" in Phi(a) or a : "TypeDefinition") \
    or "Comptime" in Phi("ft"))
   / (Phi(e) := Phi(e) union {"Comptime"}) $,
)[
  A call is compile-time known if *all its arguments are* -- types always count
  -- *or if the function's own type is comptime*. The second disjunct is why
  marking a function type comptime makes every call through it comptime
  regardless of its arguments, which is what the whole `type` namespace relies
  on.
]

#rule("C-Type", "Comptime from the type", "impl",
  $ (e : "TypeOf" quad t = "base"("TypeOf"(e)) quad "AlwaysComptime" in Phi(t)) / (Phi(e) := Phi(e) union {"Comptime"}) $,
)[
  A value whose type is always-comptime is comptime however it was produced.
  This is the rule `type.comptime` exists to trigger. Comptime parameters are
  not present in the ABI of the resulting function.
]

#rule("C-Valid", "Comptime validity", "impl",
  $ ("Comptime" in Phi(e) quad a in "inputs"(e) quad "Comptime" in.not Phi(a) quad a in.not "TypeDefinition") / ("ill-formed") $,
  kind: "bad",
)[
  A comptime call handed a runtime value is an error. One builtin is excepted by
  name -- the assembler's `register_for`, whose second argument is deliberately
  a runtime register.
]

#note("The fixpoint is not monotone", kind: "warn")[
  C-Call both *sets* and *clears* the flag: a call that stops satisfying the
  premise has it removed and the fixpoint re-runs. A non-monotone operator has
  no Knaster--Tarski guarantee, so termination is not automatic -- it holds
  because the call/argument dependency graph is acyclic, each pass settling one
  more level. *A cycle would oscillate*, and nothing currently rules one out. A
  specification should either require acyclicity explicitly or make the flag
  monotone, with a separate validity check.
]

#rule("C-Order", "Lexical order", "impl",
  $ "effects apply in lexical order: declaration order within a block, blocks depth-first" $,
)[
  Execution runs top to bottom. Name resolution does not care (R-Order) -- a
  name means the same thing wherever it is written -- but *everything that
  mutates the store does*: adding or removing a modifier, and extending an
  overload set, take effect at their own lexical position and hold from there
  onward (P2). So order decides *what a modifier does* and not *what a name
  means*, and that is the language's rule rather than a consequence of how the
  passes happen to walk the store.
]

== Deduced parameters

#note("Status", kind: "stop")[
  `deduced` appears in 36 positions in `standard.doir` -- every arithmetic,
  comparison and memory primitive. The parser recognises the keyword and emits
  "Deducible types not yet supported". These are the only diagnostics
  `standard.doir` still raises.
]

#rule("D-Deduce", "Bidirectional solving", "spec",
  $ (f : (T_r: "deduced type", T: "deduced type", v: T) -> T_r quad "typeof"(x) = tau quad "expected"(c) = rho)
   / (⟨c : rho = f(x)⟩ ⇝ f(rho, tau, x)) $,
)[
  A `deduced` parameter is *solved, not supplied* -- it is absent from the call
  site. Solutions come from two directions: *forward* from the types of the
  supplied arguments, and *backward* from the declared type of the register
  being assigned. Part I's example needs both. Elaboration is first-order
  unification, each variable fixed by its first solution; a later argument
  disagreeing with that solution makes the call ill-formed, which is what gives
  `is_equal(a, b)` its implicit same-type constraint without a where-clause.

  Deduction interacts with @identity: unification compares types, so a `unique`
  type will *not* unify with the type it was derived from. That is the point --
  it is how `type.unique` buys static checking out of a structural system.
]

== Attributes and reflection

An entity id is a pointer-sized integer and an attribute id is a component
index, so attribute operations are component operations spelled in the source
language. Everything here is comptime, so this is *staging* rather than runtime
reflection: nothing survives into the emitted binary.

#rule("A-Attr", "Attribute access", "spec",
  $ "add"(v, "id") ⇝ C_"id" (v) := "fresh" quad quad "get"(v, "id") = C_"id" (v) \
   "get_or_add"(v, "id") = C_"id" (v) "if defined, else add" $,
)[
  Attaching an attribute to a value is attaching a component to an entity.
  `attribute.get_id` is overloaded to take either a type or a name string, so a
  program can find a slot statically or by string.
]

#rule("R-Reflect", "Reflection is a retraction", "spec",
  $ "unreflect"("reflect"(v)) = v quad quad "reflect"("unreflect"(e)) = e "for" e "live" $,
)[
  `reflect` moves a value from the object language to the meta language;
  `unreflect` moves it back, and `unreflect_alias` returns a *name* for it
  rather than its value, so nothing is copied.
]

#rule("R-Square", "Reflection coherence", "spec",
  $ "meta.type".mu("reflect"(T)) space = space "reflect"("type".mu(T)) quad "for every modifier" mu $,
  kind: "mut",
)[
  `meta.type` mirrors `type` operation for operation, taking an `entity` where
  the other takes a `type` -- the unchecked version of the same operations. This
  square must commute, and *under the in-place discipline it commutes
  trivially*: both sides mutate the same entity, so there is nothing for the two
  paths to disagree about. Under a generative reading they would produce
  different entities and the law would need proving. This is a real argument for
  the discipline.
]

== Control flow

A `block` is a comptime value holding unexecuted code, and by WF-Arg it must be
named before it can be passed.

#figure(
  table(
    columns: (auto, auto, 1fr),
    stroke: none,
    inset: (x: 5pt, y: 3.6pt),
    table.hline(stroke: 0.6pt + hair),
    table.header([*Form*], [*Result type*], [*What the type is saying*]),
    table.hline(stroke: 0.6pt + hair),
    [`execute(body)`], [what `body` yields], [Runs the block here.],
    [`defer(body)`], [`void`], [Runs at *every* exit point of the enclosing block.],
    [`while(c, body)`], [`pointer(typeof(body))`], [A *pointer as an option type*: the loop may run zero times, so there may be no value, and null encodes that.],
    [`if(c, then, else)`], [`union{then, else}`], [*Untagged*; the caller discriminates. Identical branch types collapse.],
    [`yield` / `return`], [terminator], [Blocks yield, functions return (WF-Term).],
    table.hline(stroke: 0.6pt + hair),
  ),
  caption: [Control flow is ordinary functions taking blocks.],
)

Three keywords may prefix a call, and each has a type-level counterpart applying
the same flag permanently via M-Flag: `inline` with
`function.forcibly_inline`, `flatten` with `function.always_flatten`, and
`tail`, which has none -- functions are tail-optimised automatically whenever
possible, and the annotation only raises a diagnostic when this call cannot be.

#note("Untagged unions", kind: "warn")[
  `if` returning an untagged union means the language cannot tell which branch
  ran. Where the branches yield different types the result is unusable without
  an external discriminator, so in practice either both yield the same type or
  the result is discarded. A tagged union, or a rule that `if` is well-formed
  only when the branches agree, would be the two ways to close this.
]

== Modules

#rule("D-Export", "Export gates import, not lookup", "spec",
  $ (M' "imports" M quad e in M) / (e "visible in" M' <==> "Export" in Phi(e)) $,
)[
  This resolves what looks like a contradiction in the compiler: `findIn` never
  checks the flag, and it is right not to -- *export is a cross-module
  boundary, not an intra-module one*. Inside a module every declaration is
  visible to every other, exported or not. What the flag does today is keep the
  name alive through lowering, which is the same fact seen from the emitter's
  side.
]

#rule("D-ExportNS", "Exporting a namespace", "broke",
  $ ("Export" in Phi(N) quad "Namespace" in Phi(N) quad e "in the subtree of" N) / ("Export" in Phi(e)) $,
  kind: "bad",
)[
  Part I says an entire namespace can be exported at once. *The propagation is
  not implemented* -- the parser sets the flag on the namespace entity alone, so
  its members would be stripped. `standard.doir` therefore exports the members
  of `diagnostic` individually rather than relying on this.
]

#rule("I-Import", "Import is position-sensitive", "spec",
  $ "import never overwrites an existing symbol" ==> \
   "import last: local wins silently; import first: conflicts are errors" $,
)[
  One rule with two very different-feeling consequences. Placement is how you
  choose between overriding and being warned. *Import is an ordered effect*,
  like modifiers and unlike name resolution. An import written inside a
  namespace places all its symbols in that namespace.
]

== Divergences and defects <divergences>

Where the spec, `standard.doir` and the compiler disagree, *the spec is right
and the disagreement is a defect* -- there are no three-way design questions
left open in this section, only work. Two defects were confirmed by running the
compiler and are now fixed, a batch in `standard.doir` likewise; the rest are
outstanding.

=== Fixed in the compiler

#figure(
  table(
    columns: (auto, 1fr),
    stroke: none,
    inset: (x: 5pt, y: 4pt),
    table.hline(stroke: 0.6pt + hair),
    table.header([*Where*], [*What was wrong*]),
    table.hline(stroke: 0.6pt + hair),
    [`grammar.peg`, `parser.d`],
    [`FunctionType` had made `-> Type` mandatory, a regression against Part I's
     "omitting the return implies void". `standard.doir` used the optional form
     nine times, so the file could not parse past its first use. The return type
     is optional again and defaults to the `void` builtin.],
    [`verify.d`],
    [A declaration whose type is a named function type -- `f : some_t`, which is
     every declaration in `standard.doir` -- ends up with both `Valueless` and
     the `FunctionReturnType` that `sema.materialize` copies off its type.
     `verify.structure` rejected that pair, aborting the compiler. It is a
     legitimate shape: a function declared but not defined.],
    [`interface_.d`],
    [`Flatten` and `Tail` shared bit `1 << 11`, inherited from the C++, so
     `tail f(x)` was indistinguishable from `flatten f(x)`, printed as both, and
     a block carrying `Flatten` tripped the "no `Tail` on a value" check. `Tail`
     has its own bit.],
    table.hline(stroke: 0.6pt + hair),
  ),
  caption: [Compiler fixes, each with a regression test.],
)

=== Fixed in `standard.doir`

#figure(
  table(
    columns: (auto, 1fr, auto),
    stroke: none,
    inset: (x: 5pt, y: 3.6pt),
    table.hline(stroke: 0.6pt + hair),
    table.header([*Where*], [*What was wrong*], [*Rule*]),
    table.hline(stroke: 0.6pt + hair),
    [`type` namespaces], [Named `type`, a reserved identifier -- and one that
      would capture the declared type `: type` of every surrounding
      declaration. Renamed to `types`.], [WF-Kind],
    [`self`], [`export self : type = byte` is an implicit register copy.
      Now `alias`.], [V-NoImplicitCopy],
    [`meta`, `meta.types`], [Every `comptime` resolved to `meta.types.comptime`
      -- `(e: entity) -> entity` -- instead of the type-taking one. The file's
      own TODO recorded the hazard. Now spelled `std.types.comptime`.], [R-Qual],
    [`types.array_t`], [Returned `entity`, which is declared inside `meta` and
      does not resolve from `std.types` at all. Returns `type`.], [R-Unqual],
    [`diagnostic.*`], [`location: source_location` named a *namespace*, not a
      type, and one in `meta`. Now `meta.source_location.location`.], [WF-Kind],
    [`meta.unreflect_alias_t`], [Built from `unreflect_t_nocomp` -- the wrong
      `_nocomp`.], [--],
    [`pointer.immutable`], [Typed `type.type_modifier_function`; no such name
      exists.], [R-Qual],
    [`meta.reflect_t`, `unreflect_*`, `meta.types.is_t`], [Missing `: type =`,
      so each declared a valueless *value* rather than a type.], [D-Decl],
    [`types.pointer`, `types.array`], [Typed as modifiers though they are
      generative. Now `constructor_function`.], [M-Ctor],
    [`sqrt`], [Took two operands; it is unary.], [--],
    [`move`], [Called `return`, which was never declared. `return` and `yield`
      are now declared.], [WF-Term],
    [`cast`], [`Tout` was a value parameter with a dependent return type. Both
      type parameters are now `deduced`, matching Part I's `cast(x)`.], [D-Deduce],
    [`attribute.*`, Mizu core], [Nothing in either was exported, so importing
      the standard interface gave no arithmetic. The public surface is now
      exported; `_t` helper types stay internal.], [D-Export],
    [`%0`--`%5` in `attribute`], [Positional names for the two `get_id`
      overloads. Now named after what they take.], [--],
    table.hline(stroke: 0.6pt + hair),
  ),
  caption: [`standard.doir` now compiles clean apart from `deduced`.],
)

=== Outstanding

/ Type comparison is nominal (@identity): S-Struct is the rule; the compiler
  compares entities and hands every `base_type` call a discriminator. Two
  halves to fix -- `nextUnique` leaving the discriminator $0$ and reserving
  non-zero for `type.unique`, and comparison on
  $⟨"size", "alignment", "unique"⟩$ rather than $alpha$-equality. Nothing
  implements implicit conversion yet either, so no program can currently
  observe the difference; both wanted together.

/ `type.self` has no resolution rule (T-Self): the recursive-type example needs
  the type under construction, which no enclosing-scope rule reaches. Needs
  either a two-pass elaboration of type-returning functions or an explicit
  self-binder.

/ A type cannot be called (T-Construct): specified in Part I, rejected by the
  compiler as "is not a function", and there is no other spelling for aggregate
  construction.

/ `deduced` is unimplemented: 36 positions in `standard.doir`, and the only
  diagnostics that file still raises. Blocks D-Deduce, and with it `cast`.

/ The comptime fixpoint is not monotone (@comptime): C-Call both sets and
  clears, so termination rests on the call graph being acyclic and nothing
  enforces that. Either require acyclicity or make the flag monotone with a
  separate validity check.

/ `move` does not yet invalidate: normative per V-Copy / V-Move, unenforceable
  until there is a liveness analysis, and unobservable until a type is not POD.
  The two arrive together.

#v(1.5em)
#line(length: 100%, stroke: 0.7pt + hair)
#v(0.4em)
#text(size: 8.6pt, fill: muted)[
  Rules marked #status("impl") were read off the compiler in `source/doir/` --
  principally `interface_.d`, `verify.d`, `parser.d`, `pipeline/sema/lookup.d`,
  `pipeline/sema/comptime.d` and `pipeline/opt/compute_compiler_namespace.d`.
  Rules marked #status("spec") come from Part I and `standard.doir` under the
  in-place modifier discipline.
]
