// TS2300 — duplicate interface member property name. Fires on
// `interface I { x: T; x: T; }` (both with type annotations). The
// carve-out for bare-name properties (parser-bug workaround for
// `m<U>()` and `readonly _A`) doesn't apply here because both entries
// carry a type annotation.
interface Bar {
  x: number;
  x: number;
}
