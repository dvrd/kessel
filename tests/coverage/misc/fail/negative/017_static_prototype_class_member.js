// ECMA-262 §15.7.1 — it is a Syntax Error if PropName of MethodDefinition
// is `"prototype"` for any static ClassElement. Applies to static
// methods, static fields, static getters/setters, and static accessor
// properties. Instance `prototype` is fine.
class A {
	static prototype = 1;
}

class B {
	static prototype() {}
}
