// ECMA-262 §14.8.1 — `continue label;` is a SyntaxError if `label`
// does not name an IterationStatement on the LabelSet of an enclosing
// iteration. `foo:` here labels a BlockStatement; the `for` inside is
// enclosed but NOT directly labelled, so `continue foo;` fails.
//
// Compare: `foo: for (;;) continue foo;` IS valid — `foo` labels the
// iteration directly. Also `foo: bar: for(;;) continue foo;` — a
// label-chain that ultimately wraps an iteration — is valid. That
// case is exercised by the parser's eager lookahead over chained
// `Identifier :` pairs at LabelledStatement push time.
foo: {
	for (var i = 0; i < 10; i++) {
		continue foo;
	}
}
