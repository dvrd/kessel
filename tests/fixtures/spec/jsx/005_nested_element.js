// JSXElement as an attribute value AND as a child.
const a = <Foo bar={<Baz x={1} />} />;
const b = <Outer><Middle><Inner /></Middle></Outer>;
