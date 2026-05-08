// ECMA-262 Annex B.3.5 — the sloppy-mode `for (var X = init in Expr)`
// carve-out requires `X` to be a BindingIdentifier. A BindingPattern
// (destructuring) with an initializer is NOT covered; the core grammar
// rule "DeclarationPart of ForDeclaration has an Initializer" applies.
for (var {a = 1} = z in y) {}
