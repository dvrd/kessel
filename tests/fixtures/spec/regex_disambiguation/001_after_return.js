// After `return`, `/` starts a RegExp literal (return takes an expression,
// and expression context chooses regex).
function f(s) {
  return /abc/g.test(s);
}
