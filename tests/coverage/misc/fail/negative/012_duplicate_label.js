// ECMA-262 §14.13.1 — nested LabelledStatement must not reuse the
// same LabelIdentifier as an enclosing LabelledStatement. Always a
// SyntaxError, not strict-gated.
outer: {
	outer: {
		break outer;
	}
}
