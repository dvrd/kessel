// TS-D: `class implements` — single and multi-interface implements
// clauses, with and without generic type arguments on each parent.
// OXC emits `implements: [TSClassImplements{expression, typeArguments}]`
// (or `TSExpressionWithTypeArguments`); Kessel must match that deep
// structure.
interface Printable {
  print(): void;
}

interface Serializable<T> {
  serialize(): T;
}

class Plain implements Printable {
  print(): void {}
}

class Dual implements Printable, Serializable<string> {
  print(): void {}
  serialize(): string {
    return "";
  }
}

class Generic<T> implements Serializable<T> {
  serialize(): T {
    return null as T;
  }
}
