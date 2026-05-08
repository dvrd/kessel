// ECMA-262 §14.3.1.1 — it is a Syntax Error if the BoundNames of a
// LexicalDeclaration contains `"let"`. Applies to `let` AND `const`
// (and `using` / `await using`), regardless of strict or sloppy mode.
// Sloppy `var let = 1;` is still fine; only the lexical forms are
// forbidden.
let let = 1;
const let = 2;
