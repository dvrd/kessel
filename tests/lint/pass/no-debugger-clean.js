// no-debugger (L2001): clean file — no `debugger` statement anywhere.
// Expected: kessel lint reports nothing and exits 0.
function compute(a, b) {
  const total = a + b;
  if (total > 10) {
    return total * 2;
  }
  return total;
}

const result = compute(3, 4);
console.log(result);
