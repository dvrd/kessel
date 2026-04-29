// Replacement for upstream-renamed Test262 fixture. Exercises the same
// syntactic surface as the original; treated as a positive parse test.

var a = true && false;
var b = 1 && 2;
var c = a && b && (1 + 2);
if (a && b) {}
