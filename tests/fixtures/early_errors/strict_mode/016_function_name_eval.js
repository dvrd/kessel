// ECMA-262 §15.1.1 — a FunctionDeclaration / FunctionExpression whose
// BindingIdentifier is `eval` or `arguments` is a SyntaxError in
// strict mode. Sloppy script accepts `function eval() {}` (B.3).
'use strict';
function eval() {}
function arguments() {}
