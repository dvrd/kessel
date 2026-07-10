// no-case-declarations (L2025): lexical declarations directly in case blocks.
function pick(x) {
  switch (x) {
    case 1:
      let a = 1;
      return a;
    case 2:
      const b = 2;
      return b;
    case 3:
      function f() {
        return 3;
      }
      return f();
  }
  return 0;
}
