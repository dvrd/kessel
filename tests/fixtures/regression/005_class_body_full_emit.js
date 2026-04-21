// Regression: ClassBody JSON emit was stubbed as `"body": []`, hiding every
// method, field, getter, setter, constructor, and static block from the
// JSON output (raw-transfer buffer had them). Downstream consumers saw
// partial or misleading ASTs for class-heavy code.
// Fixed: print_class_body_inline iterates all ClassElement entries,
// emitting MethodDefinition / PropertyDefinition / StaticBlock with
// matching kind, computed, static fields per ESTree.
class Regression005 extends Base {
  // class fields (PropertyDefinition)
  plain = 1;
  #private = "hidden";
  static staticField = 2;
  static #staticPrivate = "private-static";
  uninitialised;

  // constructor (MethodDefinition kind="constructor")
  constructor(x) {
    super();
    this.x = x;
  }

  // regular method (MethodDefinition kind="method")
  instanceMethod(a, b) {
    return a + b;
  }

  // accessors (MethodDefinition kind="get"/"set")
  get accessor() {
    return this.#private;
  }
  set accessor(v) {
    this.#private = v;
  }

  // async + generator
  async *asyncGen(items) {
    for (const i of items) yield i;
  }

  // computed key
  [computedKey]() {
    return 42;
  }

  // static method
  static create(x) {
    return new Regression005(x);
  }

  // private method
  #privateMethod() {
    return this.#private;
  }

  // static block (StaticBlock)
  static {
    Regression005.initialised = true;
  }
}
