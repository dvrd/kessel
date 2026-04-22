// ECMA-262 §12.9.4 — `\u{H...H}` must represent a code point in
// [0, 0x10FFFF]. 0x110000 is out of range → SyntaxError at parse.
const bad = "\u{110000}";
