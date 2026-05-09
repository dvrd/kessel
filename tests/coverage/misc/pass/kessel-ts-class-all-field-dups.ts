// Lock-in: pure all-field slot duplicates are NOT flagged by the
// class member dup check. Mirrors OXC's semantic checker, which
// accepts the babel `typescript/class/properties` fixture (5x `x;`
// with TS-specific `?` and `!` modifiers) without firing TS2300.
// All TSC negative fixtures we DO close involve at least one method,
// accessor, or signature on the same slot.
class C {
  x;
  x;
  x: number;
  x: number = 1;
}
