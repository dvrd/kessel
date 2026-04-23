// Lexical: U+200C ZERO WIDTH NON-JOINER and U+200D ZERO WIDTH JOINER are
// explicitly permitted in IdentifierContinue (ECMA-262 §11.6). They must
// NOT be permitted in IdentifierStart. Below, each identifier starts with
// a regular letter and then carries a ZWJ/ZWNJ as a continuation
// character, which is the only position the spec allows.
var foo\u200Dbar = 1;   // ZWJ  at continue
var baz\u200Cqux = 2;   // ZWNJ at continue
var mix\u200D\u200Cend = 3;
