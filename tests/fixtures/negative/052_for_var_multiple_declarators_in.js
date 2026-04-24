// ECMA-262 §14.7.5 — the for-in/of head allows a SINGLE ForBinding /
// ForDeclaration only; a comma-list of declarators is a SyntaxError
// (parse error on the comma in the core grammar). Even the Annex B.3.5
// carve-out only accepts ONE declarator.
for (var x, y in z) {}
