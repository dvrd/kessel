// Replacement for upstream-renamed Test262 fixture. Exercises the same
// syntactic surface as the original; treated as a positive parse test.

function f1() {}
function f2(a, b) { return a + b; }
function f3(a, ...rest) { return rest; }
var g = function () { return 1; };
var h = function named() { return 2; };
