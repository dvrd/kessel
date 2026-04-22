// ECMA-262 §13.3.1.1 — `let` is a reserved word in strict mode, including
// as a BindingIdentifier in a `let` declaration. `let let` is a SyntaxError.
'use strict';
let let = 1;
