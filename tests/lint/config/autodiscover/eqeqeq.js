// Auto-discovery fixture: `kessel lint eqeqeq.js` run from this directory
// picks up the sibling kessel.lint.json (eqeqeq:error) without an explicit
// --config, so the loose-equality comparison must be reported.
function same(a, b) {
  return a == b;
}
same(1, 1);
