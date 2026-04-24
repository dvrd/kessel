// ECMA-262 §13.5.1 — `delete` of a PrivateFieldReference is always a
// SyntaxError. Private slots don't have a `[[Delete]]` internal method,
// so there's no way to remove them. Both `delete x.#y` and
// `delete this.#y` are rejected.
class A {
	#x = 1;
	m() {
		delete this.#x;
	}
}
