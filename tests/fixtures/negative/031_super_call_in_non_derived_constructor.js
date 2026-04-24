// ECMA-262 §15.7.3 / §13.3.7 — `super(...)` (SuperCall) is a SyntaxError
// outside the instance constructor of a class with an `extends` clause.
// Here the class has no `extends` clause, so the constructor is a BASE
// constructor and its body may not invoke super().
class A {
	constructor() {
		super();
	}
}
