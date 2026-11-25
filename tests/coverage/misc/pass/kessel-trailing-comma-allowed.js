// The places where a comma may be followed by nothing. Rejecting a dangling
// comma operator (`a, ;`, `if (a, ) {}`) must not reject any of these.
(a, ) => 1;
(a, b, ) => 1;
(a, b, c, ) => 1;
(a = (b, c), ) => 1;
(a, /* note */ ) => 1;
async (a, ) => 1;
f(a, );
f((a, ) => 1, );
new F(a, );
[a, ];
[a, , b];
({ a, });
function g(a, b, ) {}
(a, b);
x = (a, (b, c));
a, b
c, d
