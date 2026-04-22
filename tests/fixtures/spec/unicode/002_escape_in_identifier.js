// ECMA-262 §12.7 — UnicodeEscapeSequence inside an identifier MUST
// denote a code point that is itself a valid IdentifierStart/Part.
// `\u0061` (U+0061 'a') → identifier `a`. So `\u0061bc` === `abc`.
const \u0061bc = 1;
const h\u{65}llo = 2;   // `hello`
