// ECMA-262 §15.1.2 / §15.2.1 — if FormalParameters contains any non-
// simple parameter (destructuring pattern, default value, rest element)
// then UniqueFormalParameters applies in BOTH strict and sloppy mode.
// A plain `function f(a, a) {}` in sloppy is legal; the moment any
// param is non-simple, duplicates become SyntaxErrors.
function f(a, {a}) { return a; }
function g({x}, x) { return x; }
function h([a, a]) { return a; }
function i(a, ...a) { return a; }
