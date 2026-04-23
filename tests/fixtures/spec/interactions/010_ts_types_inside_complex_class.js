// Interaction: TypeScript types threaded through every member position of
// a generic class — a type parameter list, a typed field initialiser,
// typed method parameters, a typed return type, and a typed cast used as
// an expression. The parser must resolve each TS production at the right
// spot without mis-recognising the `<T>` type-parameter list as JSX or
// the `as T` as a relational expression.
class Store<T> {
  items: Array<T> = [];
  push(item: T): void {
    this.items.push(item);
  }
  get(i: number): T | undefined {
    return this.items[i];
  }
  size(): number {
    return this.items.length;
  }
  clone(): Store<T> {
    const copy = new Store<T>();
    for (const item of this.items) copy.push(item);
    return copy;
  }
}
