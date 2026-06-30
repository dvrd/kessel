// Negative space for no-dupe-class-members:
//   - get/set pair with same name is legal
//   - a static and an instance member may share a name
class C {
  get x() { return this._x; }
  set x(v) { this._x = v; }
  foo() { return 1; }
  static foo() { return 2; }
}
new C();
