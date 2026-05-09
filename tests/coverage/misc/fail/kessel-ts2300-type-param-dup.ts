// TS2300 — duplicate generic type-parameter name on a function,
// class, interface, or type alias declaration. Single-pass scan over
// TSTypeParameterDeclaration.params.
function A<X, X>() {}
