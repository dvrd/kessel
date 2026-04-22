// TS generic type parameters on a class + constructor + method.
class Box<T> {
  value: T;
  constructor(v: T) { this.value = v; }
  get(): T { return this.value; }
}
const b = new Box<number>(42);
