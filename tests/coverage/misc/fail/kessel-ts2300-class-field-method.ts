// TS2300 — class member with the same `(static, name)` slot used as
// both a field and a method (mixed kinds). The OXC-mirror gate skips
// pure all-field slots (e.g. `class C { x; x; }`), but a field
// followed by a method-impl on the same name is a real merge conflict
// that both TSC and oxc-semantic reject.
class C {
  a(): number { return 0; }
  a: number;
}
