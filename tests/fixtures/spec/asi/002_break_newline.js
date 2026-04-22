// ECMA-262 \u00a713.9 \u2014 BreakStatement has a restricted production:
// no LineTerminator between `break` and the optional Label. So
// `break\nlabel;` is `break;` + `label;` (ExpressionStatement).
outer: for (;;) {
  break
  outer
}
