// ECMA-262 §14.7.5.1 — "It is a Syntax Error if DeclarationPart of
// ForDeclaration has an Initializer." Only `var` survives via the
// Annex B.3.5 carve-out; `let` / `const` / `using` must reject an
// initializer in a for-in head.
for (let x = 1 in y) {}
