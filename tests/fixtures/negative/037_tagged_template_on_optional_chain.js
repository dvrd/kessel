// ECMA-262 §13.3.5 — A TaggedTemplateExpression whose tag is an
// OptionalExpression is a Syntax Error. The grammar deliberately
// forbids composing tagged templates with optional chaining because
// the runtime semantics of `undefined?.foo\`t\`` would be ambiguous
// (do we invoke with undefined tag? skip the template evaluation?).
// Once we're inside a `?.`-chained expression, any template tail
// terminates the chain with an early error.
obj?.foo`template`;
