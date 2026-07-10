// Class member modifiers, field types, generics, and abstract/overload
// members are all erased; runtime members survive.
abstract class Shape<T> extends Base implements Drawable {
  private origin: T;
  readonly id!: number;
  static count: number = 0;
  constructor(o: T) {
    this.origin = o;
  }
  translate<U>(by: U): T {
    return this.origin;
  }
  abstract area(): number;
}
