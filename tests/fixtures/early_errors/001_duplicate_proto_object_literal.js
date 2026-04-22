// ECMA-262 §12.2.6.1 — __proto__ property used twice as an actual identifier
// key in the same object literal is a SyntaxError. (Computed/shorthand
// forms are allowed; these are literal identifier keys.)
const bad = { __proto__: 1, __proto__: 2 };
