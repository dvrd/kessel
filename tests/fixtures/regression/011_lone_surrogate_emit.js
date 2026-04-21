// Regression: lone UTF-16 surrogates in string literals were round-tripped
// through WTF-8 in the cooked buffer (lex_string_scalar → append_utf8 emits
// 0xED 0xA0-BF 0x80-BF for U+D800..U+DFFF), but out_string streamed those
// raw bytes to stdout. JSON forbids raw surrogate bytes; `JSON.parse` on
// the resulting output normalises the invalid-UTF-8 triple to three U+FFFD
// replacement characters, diverging from OXC which escapes surrogates as
// `\uXXXX` in the JSON output.
//
// Surfaced by Bug I-5 (ClassBody JSON emit): handsontable.js contains 2
// lone-surrogate strings whose `value` mismatched OXC (compared=6270,
// mismatches=2 with `\uDEAD` and `\uD834\uDF06` — the latter a PAIR where
// the high surrogate appears *after* the low in source order, so it does
// not combine into a BMP supplementary character and both stay lone).
//
// Fix: `wtf8_surrogate_at` detects the 3-byte WTF-8 triple at emit time in
// `out_string` / `out_string_inner`; every detected surrogate is escaped
// as `\uXXXX` (lowercase hex, matching OXC). ECMA-262 permits lone
// surrogates in string literals, so the ESTree `value` field round-trips
// through JSON as a 1-codepoint string, preserving the surrogate.
//
// This fixture exercises every interesting shape from ECMA-262 §12.9.4:

// Bare lone low surrogate at BOF of the value.
const a = "\uDEAD";

// Bare lone high surrogate.
const b = "\uD834";

// Lone surrogate surrounded by normal BMP characters.
const c = "x\uDEADy";

// Reversed "pair" — a low followed by a high is NOT a valid surrogate
// pair under UTF-16 (high must precede low), so both stay lone.
const d = "\uDF06\uD834";

// Valid surrogate pair (U+1D306, 𝌆 TETRAGRAM FOR CENTRE). This must NOT
// regress: it should decode to one supplementary-plane codepoint and
// emit either as the 4-byte UTF-8 or as the `\uD834\uDF06` pair depending
// on convention. Either way, no U+FFFD.
const e = "\uD834\uDF06";

// Mix of ASCII, valid pair, lone surrogate, and BMP punctuation.
const f = "hi \uD834\uDF06 and \uDEAD plus \u2603!";

// Multiple lone surrogates back-to-back.
const g = "\uD800\uD801\uDFFF";

// Template literal with surrogate (templates don't cook escapes today but
// we still want to exercise the `raw` path and confirm no SIGSEGV).
const h = `plain \uDEAD template`;

// Emit within an object-literal value, exercising the full emit call chain
// through print_expression_ast → ObjectExpression → print_expression_ast
// → StringLiteral → out_string.
const objWithSurrogates = {
  key1: "\uDEAD",
  key2: "normal",
  key3: "\uD834\uDF06",  // valid pair
  key4: "mix \uDC00 middle",
};
