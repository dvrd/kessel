// ECMA-262 §15.7.1 — a class body may not declare two PrivateElements
// with the same PrivateIdentifier `#name`, nor a PrivateIdentifier
// whose description is `constructor`. Covers both: the duplicate `#x`
// and the forbidden `#constructor`.
class A {
	#x = 1;
	#x = 2;
}

class B {
	#constructor() {}
}
