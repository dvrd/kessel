// Realistic TSX generic-component pattern. Exercises the JSX↔TS-generic
// disambiguation surface that the ambiguity/ fixtures cover only as
// minimal stress tests. Here the same surface appears as it does in
// real component libraries (zustand, framer-motion, react-bootstrap):
//
//   * Generic function component declaration `<T,>` with the trailing
//     comma syntax used by tsx-friendly projects to avoid the JSX
//     parser interpreting `<T>` as an opening tag
//   * An interface defining the prop shape with optional / required
//     fields and a generic on the function-typed `render` prop
//   * `as` cast inside a JSXExpressionContainer child
//   * Generic call-form construction `List<User>({...})` — the JSX
//     call-site type-argument form `<List<User> />` is not yet
//     supported by kessel (matches parsers like swc; OXC accepts it).
//     Demonstrating the call-form keeps the fixture green while still
//     exercising the generic-on-component pattern.
//
// Parsed with --lang=tsx (auto-discovered from spec/tsx/).
interface ListProps<T> {
  items: readonly T[];
  render: (item: T, index: number) => JSX.Element;
  emptyMessage?: string;
  keySelector?: (item: T) => string | number;
}

function List<T,>({ items, render, emptyMessage, keySelector }: ListProps<T>) {
  if (items.length === 0) {
    return <div className="empty">{emptyMessage ?? "no items"}</div>;
  }
  return (
    <ul className="list">
      {items.map((it, i) => (
        <li key={(keySelector ? keySelector(it) : i) as string | number}>
          {render(it, i)}
        </li>
      ))}
    </ul>
  );
}

interface User { id: string; name: string; admin?: boolean }

function UserDirectory({ users }: { users: User[] }) {
  const sorted = [...users].sort((a, b) => a.name.localeCompare(b.name));
  return (
    <List
      items={sorted}
      keySelector={(u: User) => u.id}
      render={(u: User) => (
        <span className={u.admin ? "admin" : "regular"}>{u.name}</span>
      )}
    />
  );
}
