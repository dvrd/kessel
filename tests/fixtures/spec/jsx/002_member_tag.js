// JSX supports member-expression tag names. ESTree: JSXMemberExpression
// recurses (.object can itself be a JSXMemberExpression).
const a = <Foo.Bar />;
const b = <Foo.Bar.Baz />;
const c = <A.B.C.D x={1} />;
