// Replacement for upstream-renamed Test262 fixture. Exercises the same
// syntactic surface as the original; treated as a positive parse test.

{}
{ var a = 1; }
{ let b = 2; { let c = 3; } }
{ ; ; }
