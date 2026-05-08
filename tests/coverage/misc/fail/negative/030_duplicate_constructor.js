// ECMA-262 §15.7.1 — a class body may declare at most one
// ClassElement whose PropName is `"constructor"` with kind Method.
// Static methods named `constructor` don't count, and getters /
// setters named `constructor` are already separately forbidden.
class A {
	constructor() {}
	constructor() {}
}
