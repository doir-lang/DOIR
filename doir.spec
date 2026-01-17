
// Every line* represents assignment to a virtual register and can take one of seven forms:
%1 : i32 = 5 // #1 Constant assignment (name : type = value)
%2 : block = { // #2 Block assignment (%2 stores "quoted" information about the contents of the block)
	%1 : i32 = 6
	_ : _ = yield(%1) // #3 Function execution (_ in a name will use the next numbered register, _ in a type will request inference)
}
%3 : alias = %2 // #4 Alias assignment (%3 is resolved to %2)
math : namespace = { // #5 Namespace assignment (note that registers can be named not just numbered)
	vec2 : type = { // #6 Type assignment
		x : f32 // #7 Undefined assignment
		y : f32
	}
}

// The * in the previous section is that doir also supports changing to another available language
//	Said language is parsed inline contributing its IR to that of the surrounding code
language "C" { // Assuming that a C language doir implementation can be found by the compiler
	int main() {
		printf("Hello World\n");
	}
}

%4 : f32 = 0.0 <"main.cpp":32:1-8> // Assignments may optionally be followed by source location information <"?filename"?:line_start(-line_end)?:column_start(-column_end)?>
%4again : f32 = 0.0 <main.cpp:32:0> // If the column is set to zero, the length of the entire line will be computed (NOTE: Error if line_start != line_end)
// Types can be used as functions with a parameter for each of their fields
vector : math.vec2 = math.vec2(%4, %4) // namespaces prepend their name to all registers inside of them (mangling rules depend on the currently loaded mangler)

// By default an assignment isn't visible outside the module (or object file) however it can be exported
vec3 : type = { x : f32 y : f32 z : f32 } // Multiple assignments can be on a single line if separated with a semicolon
_ : _ = module.export(vec3)

// Functions can only take register names (as above)
%5 : i32 = execute({
	%1 : i32 = 6
	_ : _ = yield(%1) // INVALID!
})
%6 : i32 = add(%1, %5) // Note: constants must be stored in a register first thus add(5, 6) is invalid

// Functions are created in the same way as a block, however their type is (args...) -> return
pchar : type = type.pointer(i8)
ppchar : type = type.pointer(pchar)
%7 : (_ : i32, _ : ppchar) = { // Omitting the return implies void
	_ : _ = printf("%g", %6) // Functions can "capture" registers in their parent scope
	_ : _ = return() // Functions must end with a call to a terminator function such as return or halt
}
main : alias = %7 // Functions can be anonymous as %7 or can be given names, additionally anonymous functions can have names aliased to them later

// Control flow is done via functions
%8 : i1 = true
%9 : block = { // if(condition, true block, false block)
	%1 : f32 = 5.0 _ : _ = yield(%1)
}
%10 : block = { _ : _ = yield(%4) }
%11 : f32 = if(%8, %9, %10)

// Functions can be forcibly inlined
%12 : f32 = inline add(%4, %4)
// It can also be applied to the function type
inline_add_t : type = function.forcibly_inline((i32, i32) -> i32)
auto_inlined_add : inline_add_t = { ... }

// Functions can alternatively require tail-call optimization be applied
%13 : f32 = tail add(%4, %4) // NOTE: Functions will be automatically tail-call optimized whenever they can be, this just throws an error diagnostic if this call can't

// When a function is inlined its code will be in a new block, if that block is undesirable the function can instead be flattened
%12alt : f32 = flatten add(%4, %4)
// And can be applied to the function type
flatten_add_t : type = function.always_flatten((i32, i32) -> i32)

// Functions can have their Application Binary Interface (ABI) name changed
%14 : byte_pointer = "some_mangled_add\0" // NOTE: `byte_pointer` is provided by the standard interface
_ : _ = function.abi_rename(add, %14)

// Function parameters can be marked as comptime, they will not be present in the ABI of the resulting function
// Additionally, their names may be mangled based on the currently loaded mangler
comp_i32 : type = type.comptime(i32)
comp_pow : (mantissa : comp_i32, base : i32) = {
	pi32 : type = type.pointer(i32)
	x : pi32 = stack.allocate(i32) // A pointer to stack memory can be allocated
	%1 : i32 = 0
	%2 : i32 = pointer.load(x) // Values can be loaded from pointers
	%3 : i32 = subtract(%2, %1)
	%4 : i32 = pointer.store(x, %3) // Values can be stored in pointers // NOTE: %3 == %4
	// Registers are all single static assignment... thus there is no concept of const in the language
	// However pointers can be marked as immutable which will throw an error diagnostic if a value is then stored in them
	const_pi32 : type = pointer.immutable(pi32)
	%5 : const_pi32 = cast(x)
	%6 : void = pointer.store(%5, %3) // Error!

	_ : _ = return()
}

// Some types such as `type` or `block` are implicitly comptime
my_add: (T : type, a : T, b : T) -> T = { ... }

// Types don't have to be explicitly defined when calling a function they can be deduced
my_promote: (Tret : deduce type, T : deduce type, value : T) -> Tret = { ... } // Note: the return type of the function can also be deduced
%12 : i32 = my_promote(%4) // Tret = i32, T = f32

// DOIR types are structural, if they have the same layout they will implicitly convert
// This can be disabled by making a unique type
list : (T : type) -> T = {
	pself : type = type.pointer(type.self) // type.self is a special type that refers to the current type (P.S. How am I gonna implement this magic?)
	out : _ = type {
		value : T
		next : pself
	}
	_ : _ = return(out)
}
int_list : type = list(i32)
%13 : _ = bss.allocate(int_list)
unique_int_list : type = type.unique(int_list)
%14 : int_list = pointer.load(%13) // Perfectly fine
%15 : unique_int_list = pointer.load(%13) // Error!
%16 : unique_int_list = cast(%14) // Perfectly fine

// Assignments can be imported from other functions, by default if a symbol already exists it won't be imported...
// 	Thus an import at the end of a file will override any imported symbols with those already in the file
//	While an import at the top of a file will cause errors if symbols conflict
path : null_terminated_byte_pointer = "path/to/file.doir\0"
_ : _ = import(path)
C : namespace = {
	stdint : null_terminated_byte_pointer = "path/to/stdint.doir\0"
	_ : _ = import(stdint) // If an import is inside a namespace all of the symbols will also be in that namespace
}

// By default assignments are internal (not visible when imported) to make them visible they need to be `export`ed.
%16272 : (%16273: deduce type, %16274: %16273, %16275: %16273) // Some obfuscated function
export my_library_add : alias = %16272

// An entire namespace can be exported at once (everything inside the namespace is implicitly exported)
export print : namespace = {
	number : (value: i32) = { /*...*/ }
	string : (value: null_terminated_byte_pointer) = { /*...*/ }
}

// --------------------------------------------------------------------------------------------------------------------------------
// PEG Grammar
// --------------------------------------------------------------------------------------------------------------------------------
// TitleCase productions need whitespace handling (- or wsc) after them when they are used... snake-case productions handle whitespace themselves
program <- _ assignment* !. # `!.` indicates end of input
assignment <- change_language / (<'export'>_)? Identifier _ ':'_ Type wsc (_ '='_ assignment_value)? (SourceInfo wsc)? Terminator _
assignment_value <- Constant wsc / Block wsc / function_call / Identifier wsc / Type wsc

change_language <- 'language'_ '"' < StringChar* > '"'_ matching_braces _
matching_braces <- '{' enforested_content* '}'
enforested_content <- matching_braces / [^{}]

deducible_type <- ('deduced'_)? Type _
parameter <- Identifier _ ':'_ deducible_type ('='_ Constant _)?
FunctionType <- '('_ (parameter (','_ parameter)*)? ')' (_ <'->'>_ Type)?
Type <- FunctionType / Identifier

Block <- '{'_ assignment* '}'
function_call <- (<'flatten' | 'inline' | 'tail'>_)? Identifier _ '('_ (Identifier _ (','_ Identifier _)*)? ')'wsc

Terminator <- ';' | '\n' | '\r\n' | '\r'
Identifier <- !Keywords < ([%]/UnicodeIdentifierStart)([.]/UnicodeIdentifierContinue)* >
Keywords <- ('deduced' | 'export' | 'flatten' | 'inline' | 'tail')_
SourceInfo <- ('<"' < (!'"' .)* > '":' / '<' < (!':' .)* > ':') < IntegerConstant > (<'-' IntegerConstant >)? ':' < IntegerConstant > (<'-' IntegerConstant > )? '>'

Constant <- < FloatConstant > / < IntegerConstant > / ('"' < StringChar* > '"') / ('\'' < StringChar > '\'')
IntegerConstant <- ('0x' HexDigit+) / ('0b' [01]*) / ('0' [0-7]*) / ([1-9][0-9]*)
FloatConstant <- ('0x' (HexDigit* '.' HexDigit+ / HexDigit+ '.'?) ([pP][+\-]? [0-9]+)?)
	/ (([0-9]* '.' [0-9]+ / [0-9]+ '.'?) ('e'i[+\-]? [0-9]+)? )
StringChar <- (!['"\n\\] .) / ('\\' ['\"?\\%abfnrtv]) / ('\\' [0-7]+) / ('\\x' HexDigit+) / ('\\u' HexDigit HexDigit HexDigit HexDigit)
HexDigit <- [a-f0-9]i

_ <- ([ \t\n\v\f\r\x85\xA0\u2028\u2029\u0020\u3000\u1680\u2000-\u2006\u2008-\u200A\u205F\u00A0\u2007\u202F] / LongComment / LineComment)*
wsc <- ([ \t\v\f\x85\xA0\u2028\u2029\u0020\u3000\u1680\u2000-\u2006\u2008-\u200A\u205F\u00A0\u2007\u202F] / LongComment / LineComment)*
LongComment <- '/*' (!'*/'.)* '*/'
LineComment <- ('//' | '#') (!'\n' .)*
