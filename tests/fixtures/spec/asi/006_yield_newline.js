// ECMA-262 \u00a715.5 \u2014 No LineTerminator between `yield` and
// AssignmentExpression (restricted production inside a generator).
// `yield\n1` is `yield;` + `1;` within the generator body.
function* g() {
  yield
  1
  yield 2
}
