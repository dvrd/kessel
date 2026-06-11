// Regression: one regex that triggers BOTH quantifier-structure early
// errors now produced by the single merged walker (regex.odin item 10):
//   * `(?<=a)*` — a quantifier applied to a lookbehind assertion.
//   * `|*c`     — a leading quantifier with no preceding atom after `|`.
// Guards the merged pass's emission order (leading-quantifier diagnostics
// first, then lookbehind diagnostics) and that neither rule was dropped.
var re = /(?<=a)*b|*c/;
