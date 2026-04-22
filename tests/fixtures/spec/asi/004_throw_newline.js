// ECMA-262 \u00a714.14 \u2014 Restricted production: ThrowStatement. No
// LineTerminator between `throw` and its Expression. `throw\nfoo` is
// a SyntaxError (ASI would produce `throw;` which is invalid by grammar).
//
// POSITIVE variant: same-line, must parse.
function bad() {
  throw new Error("oops");
}
