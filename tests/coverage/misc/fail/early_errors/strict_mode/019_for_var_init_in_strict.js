// ECMA-262 Annex B.3.5 — the `for (var X = init in Expr)` carve-out
// is explicitly sloppy-mode only. In strict mode the core §14.7.5.1
// rule "It is a Syntax Error if DeclarationPart of ForDeclaration has
// an Initializer" fires. Placed under early_errors/strict_mode so the
// verifier pins `--source-type=script` + `"use strict"` automatically.
"use strict";
for (var x = 1 in y) {}
