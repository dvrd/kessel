// ECMA-262 §13.3.10 / §13.3.12 — ImportCall (`import(specifier)`) is
// not a valid NewExpression callee. `new import("x")` is a SyntaxError.
new import("./m.js");
