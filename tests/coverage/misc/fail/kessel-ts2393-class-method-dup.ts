// TS2393 — class with two method-impls of the same `(static, name)`
// slot. Each impl is flagged. Carve-outs for the babel
// const-type-parameters parser-test fixture (impls with generic
// type_parameters) don't apply here — these impls have no type params.
class C {
  b() {}
  b() {}
}
