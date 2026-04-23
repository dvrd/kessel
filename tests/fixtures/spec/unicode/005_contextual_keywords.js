// Contextual keywords — `async`, `await`, `yield`, `of`, `from`, `as`,
// `get`, `set`, `target`, `meta`, `static`, `let` — may appear as
// identifiers in non-reserved positions.
//
// Note: `let` is intentionally NOT tested in a `const` BindingList
// because ECMA-262 §14.3.1.1 explicitly forbids the BoundNames of a
// LexicalDeclaration from containing "let". `var let = 12;` stays
// legal (B.3.4.4 / sloppy-mode allowance) and is exercised by
// spec/lexical/ fixtures separately.
const async = 1;
const await = 2;
const get = 3;
const set = 4;
const of = 5;
const from = 6;
const as = 7;
const target = 8;
const meta = 9;
const static = 10;
const yield = 11;
var let = 12;
