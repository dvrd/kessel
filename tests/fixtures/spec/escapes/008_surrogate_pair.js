// Valid UTF-16 surrogate pair as two \uXXXX escapes. The pair decodes to
// one supplementary-plane code point. U+D834 U+DF06 = U+1D306 (𝌆).
const pair = "\uD834\uDF06";
// Lone surrogates (high without low, low without high) are allowed as
// LITERAL values by ECMA-262 §12.9.4 — round-trip must preserve them.
// Covered by tests/fixtures/regression/011_lone_surrogate_emit.js.
