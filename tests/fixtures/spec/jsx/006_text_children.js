// Plain text and expression children. Whitespace handling follows JSX
// conventions: leading/trailing newlines may be trimmed, interior
// single-space runs preserved.
const a = <p>hello world</p>;
const b = <div>Before {expr} after</div>;
const c = <span>{1 + 2}</span>;
