// Realistic JSX function-component pattern. Exercises:
//   * `useState` / `useEffect` calls inline in component body
//   * destructuring import-like patterns from a hook return
//   * conditional rendering with logical && and ternary
//   * list rendering via `.map` returning JSXElement children with keys
//   * className composition via template literal
//   * spread + override on a JSXSpreadAttribute followed by named attrs
//   * an event handler defined inline as an arrow function passed via
//     a JSXExpressionContainer attribute value
//
// Together these cover the most common JSX shapes a real component file
// hits — beyond the single-feature primitives 001-008 — without any
// TS-specific syntax (kept .jsx-clean so the gate parses with --lang=jsx).
function Counter({ items, initial }) {
  const [count, setCount] = useState(initial ?? 0);
  const [filter, setFilter] = useState("");

  useEffect(() => {
    document.title = `Counter: ${count}`;
    return () => { document.title = "App"; };
  }, [count]);

  const visible = items.filter((it) => it.label.includes(filter));

  return (
    <div className={`counter ${count > 10 ? "high" : "low"}`}>
      <header>
        <h1>{count} items</h1>
        {count > 0 && <button onClick={() => setCount(0)}>reset</button>}
      </header>
      <input
        type="text"
        value={filter}
        onChange={(e) => setFilter(e.target.value)}
        placeholder="filter…"
      />
      {visible.length === 0 ? (
        <p className="empty">no matches</p>
      ) : (
        <ul>
          {visible.map((it, idx) => (
            <li key={it.id ?? idx} {...it.extraProps} data-index={idx}>
              <span>{it.label}</span>
              {it.badge && <em>{it.badge}</em>}
            </li>
          ))}
        </ul>
      )}
      <footer>
        <button onClick={() => setCount(count + 1)}>+1</button>
        <button onClick={() => setCount(count - 1)}>-1</button>
      </footer>
    </div>
  );
}
