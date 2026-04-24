// ECMA-262 §15.3.1 — "It is a Syntax Error if ArrowParameters Contains
// AwaitExpression is true." The rule applies to BOTH async and
// non-async arrows. The cover `(x = await 1)` parses legally inside an
// enclosing async function (where `await 1` is a valid AwaitExpression),
// so we can only detect the violation once the `=>` commits the cover
// to arrow parameters. parse_arrow_function walks the cover expression
// and reports retroactively.
async function outer() {
  return (x = await 1) => x;
}
