// Realistic TSX hooks + refs + as-cast pattern. Covers shapes that
// only appear in TSX, not pure JSX:
//
//   * `useRef<HTMLDivElement>(null)` — generic call inside a function
//     body, distinct from the JSX-tag form
//   * `e as KeyboardEvent` cast inside a JSX event-handler body
//   * Discriminated-union prop type with TSAsExpression in JSX child
//   * `<Icon as={MyIcon} />` polymorphic-component pattern (the prop
//     value is itself a component reference, common in mantine /
//     chakra-ui)
//   * Type parameter on a useReducer call: `useReducer<typeof reducer>`
//   * Hook return type asserted via `satisfies` in a separate const
//   * useState with explicit generic: `useState<string | null>(null)`
//
// Parsed with --lang=tsx (auto-discovered from spec/tsx/).
type Action =
  | { type: "set"; value: string }
  | { type: "clear" }
  | { type: "append"; suffix: string };

function reducer(state: string, action: Action): string {
  switch (action.type) {
    case "set":    return action.value;
    case "clear":  return "";
    case "append": return state + action.suffix;
  }
}

const initialState: string = "" satisfies string;

function Editor({ id, As }: { id: string; As?: React.ElementType }) {
  const ref = useRef<HTMLDivElement>(null);
  const [draft, setDraft] = useState<string | null>(null);
  const [state, dispatch] = useReducer<typeof reducer>(reducer, initialState);

  useEffect(() => {
    const node = ref.current as HTMLDivElement;
    const onKey = (e: Event) => {
      const k = e as KeyboardEvent;
      if (k.key === "Escape") dispatch({ type: "clear" });
    };
    node.addEventListener("keydown", onKey);
    return () => node.removeEventListener("keydown", onKey);
  }, []);

  const Comp = As ?? "div";

  return (
    <Comp ref={ref} id={id} contentEditable suppressContentEditableWarning>
      <strong>Draft:</strong>
      {(draft ?? state) as string}
      <button onClick={() => dispatch({ type: "append", suffix: "!" })}>
        bang
      </button>
      <input
        type="text"
        defaultValue={state}
        onChange={(e) => setDraft((e.target as HTMLInputElement).value)}
      />
    </Comp>
  );
}
