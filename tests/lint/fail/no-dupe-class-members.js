// no-dupe-class-members (L2004): duplicate method name.
class C {
  foo() { return 1; }
  bar() { return 2; }
  foo() { return 3; }
}
new C();
