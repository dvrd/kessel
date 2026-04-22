// Ambiguous-looking: a bare identifier, then newline, then a regex-like
// token. ASI applies because `/` starts a valid new ExpressionStatement.
// So `x\n/foo/` parses as `x;` + `/foo/;`.
let x = 0
/foo/g
