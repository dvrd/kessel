// ECMA-262 §12.9.4 — \x requires exactly 2 hex digits. Fewer (or
// non-hex next character) is a SyntaxError.
const bad = "\x4";
