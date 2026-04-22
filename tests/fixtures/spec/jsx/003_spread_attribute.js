// JSX spread attribute: <Foo {...props} />. ESTree:
// JSXSpreadAttribute.argument = Expression.
const a = <Foo {...props} />;
const b = <Bar x={1} {...rest} y={2} />;
