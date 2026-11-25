// `{...xs}` in child position is a JSXSpreadChild whose span includes both
// braces; its operand is any assignment expression.
const one = <a>{...xs}</a>;
const mixed = <a>text{...xs}{y}{/* empty */}{...(cond ? left : right)}</a>;
const fragment = <>{...xs}{...await_like()}</>;
const nested = <a><b>{...[1, 2, 3]}</b></a>;
