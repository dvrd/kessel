declare const key: unique symbol;

export type Fields = {
  readonly [Symbol /* member */ .iterator]?: () => Iterator<number>;
  mutable: boolean;
};
type Named = { readonly [key]: number };
type Literal = { readonly ["value"]: string };
type Index = { readonly [name: string]: number; next?: number };
type Mapped<T> = { readonly [K /* parameter */ in keyof T]?: T[K] };
type Mutable<T> = { -readonly [K in keyof T]: T[K] };
type Frozen<T> = { +readonly [K in keyof T]: T[K] };
type Separate = { readonly
  [key]: number };
