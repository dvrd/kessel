// ECMA-262 §14.7.5.1 — the Annex B.3.5 carve-out that lets
// `for (var X = init in Expr)` survive in sloppy mode does NOT extend
// to for-of. A `var` declarator with an initializer in a for-of head
// is still a SyntaxError.
for (var x = 1 of y) {}
