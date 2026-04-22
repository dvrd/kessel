// ECMA-262 §12.9.4 — NonEscapeCharacter: any SourceCharacter that is not
// one of the recognised escapes, `0` followed by a digit, `x`, `u`, or a
// LineTerminator. Identity-escapes to itself.
const a = "\h";  // "h"
const b = "\z";  // "z"
const c = "\$";  // "$"
const d = "\@";  // "@"
