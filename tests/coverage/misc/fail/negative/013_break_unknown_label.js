// ECMA-262 §14.14.1 — `break foo;` where no enclosing LabelledStatement
// uses the label `foo` is a SyntaxError. Same rule applies to
// `continue foo;`. Unlabelled `break`/`continue` outside a loop/switch
// is already covered by fixtures 009/010 in this directory.
foo: {
	break bar;
}
