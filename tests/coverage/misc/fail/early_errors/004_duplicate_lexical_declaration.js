// ECMA-262 §13.3.1.1 — the LexicalDeclaration BoundNames list must have
// no duplicates. `let x = 1, x = 2;` is a SyntaxError regardless of mode.
let x = 1, x = 2;
