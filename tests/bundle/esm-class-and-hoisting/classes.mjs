export class Base {
  describe() { return 'base:' + this.constructor.name; }
}
export class Derived extends Base {
  static count = Derived.name.length;
  static #secret = 3;
  static reveal() { return Derived.#secret; }
}
export function make() { return new Derived(); }
