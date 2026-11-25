// An escaped surrogate pair in a template cooks to one supplementary code point,
// as it does in a string literal. The cooked bytes are pinned by
// test_cooked_surrogate_pairs_are_joined in tests/coverage/src/hardening_test.odin.
var pair = `\uD83D\uDE00`;
var braced = `\u{D83D}\u{DE00}`;
var mixed = `a\uD83D\u{DE00}b${pair}\uD83D\uDE00`;
var lone = `\uD83D` + `\uDE00`;
var reversed = `\uDE00\uD83D`;
var string = "\uD83D\uDE00" + "\u{D83D}\u{DE00}";
