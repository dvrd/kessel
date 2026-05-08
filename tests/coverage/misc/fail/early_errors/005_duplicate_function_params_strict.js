// ECMA-262 §15.2.1 — in strict mode, FunctionDeclaration with two
// parameters of the same name is a SyntaxError. (Allowed in sloppy.)
'use strict';
function f(a, a) { return a; }
