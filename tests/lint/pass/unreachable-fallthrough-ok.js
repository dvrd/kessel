// Valid: no-unreachable should not fire, no-fallthrough should not fire.
function foo() { return 1; }
switch (x) {
  case 1: foo(); break;
  case 2: bar(); break;
  default: baz();
}
