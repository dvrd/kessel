// ECMA-262 §12.9.4 — \uXXXX requires exactly 4 hex digits. `\u12Z4`
// is a SyntaxError (Z is not a hex digit).
const bad = "\u12Z4";
