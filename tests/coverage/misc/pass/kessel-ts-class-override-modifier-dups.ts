// Lock-in: slot-level gate for TS-only modifiers (`override`,
// `definite`, `optional`) suppresses dup detection on the whole slot.
// Mirrors OXC's semantic checker, which accepts the babel
// `typescript/class/modifiers-override` fixture without firing
// TS2393 on `override show()` + `public override show()`.
class MyClass extends BaseClass {
  override show() {}
  public override show() {}
}
