// Lock-in: TS2448 must NOT fire when the reference is inside a
// nested function / arrow / method / class body. Those bodies are
// closures — refs are evaluated when CALLED, not when the closure
// is defined, so by the time `fn` runs `x` is in scope.
function ok1() {
  const f = () => x;     // arrow body, deferred
  let x = 1;
  return f;
}

function ok2() {
  const g = function () { return x; };   // function expr body, deferred
  let x = 2;
  return g;
}

function ok3() {
  class C {
    m() { return x; }    // method body, deferred
  }
  let x = 3;
  return new C();
}

// Lock-in: TS type positions are erased at runtime — references in
// `typeof X` and inside type annotations don't trigger TS2448.
function ok4() {
  type T = typeof y;
  let y: number = 1;
  return y;
}
