// ECMA-262 §15.7.3 / §13.3.7 — `super(...)` (SuperCall) is a SyntaxError
// in any class method body that is not the instance constructor of a
// derived class. SuperProperty (`super.x` / `super[x]`) remains legal
// in all class methods, but the CALL form is restricted to the
// derived-class constructor body (plus arrow functions nested inside
// it, which is not what this fixture tests).
class B {}
class D extends B {
	method() {
		super();
	}
}
