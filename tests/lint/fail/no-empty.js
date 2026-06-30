// no-empty (L1001): contains a bare empty block statement.
// Expected: kessel lint reports the diagnostic and exits 1.
function check(x) {
  if (x) {
  }
  return x;
}

check(1);
