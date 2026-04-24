// ECMA-262 §15.8.1 / §15.6.1 — the same await-in-params rule as
// AsyncFunctionDeclaration applies to class and object-literal async
// method shorthand. `class C { async m(x = await 1) {} }` is a
// SyntaxError because the parameter default initializer is outside the
// async method's environment.
class C {
  async m(x = await 1) {}
}
