// no-debugger (L2001): contains a `debugger` statement.
// Expected: kessel lint reports the diagnostic and exits 1.
function compute(a, b) {
  debugger;
  return a + b;
}

compute(1, 2);
