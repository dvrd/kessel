// ECMA-262 §12.7 — ZWJ (U+200D) and ZWNJ (U+200C) are allowed inside
// an identifier as IdentifierPart (not as IdentifierStart).
// This is important for languages like Persian and Hindi.
const foo‌bar = 1;  // contains ZWNJ
const baz‍qux = 2;  // contains ZWJ
