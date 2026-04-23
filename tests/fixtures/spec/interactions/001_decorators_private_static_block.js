// Stacked feature interaction: class decorators + method decorators +
// private fields + private field initializers + static block initializer.
// The parser must handle the decorator positions before `class` and before
// a method, AND still accept `#name` private identifiers, AND still allow
// a `static { ... }` block inside the class body. Each feature alone is
// covered elsewhere in `spec/`; this file proves they coexist.
function frozen(C) { return C; }
function bound(_target, _key, descriptor) { return descriptor; }

@frozen
class A {
  static #count = 0;
  #id;

  constructor(id) {
    this.#id = id;
    A.#count++;
  }

  @bound
  value() {
    return this.#id;
  }

  static {
    // Static-block initialisers run once per class evaluation and can
    // access private static members of the enclosing class.
    A.#count = 0;
  }
}
