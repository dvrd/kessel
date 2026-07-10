// Generic type parameters and type arguments are erased.
function identity<T>(x: T): T {
  return x;
}
const wrap = <T>(v: T): T[] => [v];
const made = identity<number>(5);
class Container<T> {
  items: T[] = [];
}
