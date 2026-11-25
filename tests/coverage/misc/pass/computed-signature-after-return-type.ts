export interface Entries<T> {
  get<K>(key: K): T;
  set<K>(key: K, value: T): void;
  readonly<U>(): U;
  static<U>(): U;
  get current(): T;
  last(): T
  [Symbol.iterator](): Iterator<T>
  values: T[] /* A newline also separates computed members in comments.
  */ [Symbol.toStringTag]: string
  first: T[
    keyof T
  ]
}

export declare function entries(): Entries<string>;
