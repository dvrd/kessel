// ECMA-262 §15.3.1 — "It is a Syntax Error if ArrowParameters Contains
// YieldExpression is true." Same rule as AwaitExpression: an arrow's
// params are evaluated in the caller's scope, so a YieldExpression in
// a default can't target the enclosing generator. The cover parses
// cleanly inside a generator body; parse_arrow_function walks the cover
// at `=>` commit and rejects.
function* outer() {
  return (x = yield 1) => x;
}
