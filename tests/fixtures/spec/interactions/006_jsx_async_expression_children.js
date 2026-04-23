// Interaction: JSX element whose attribute and child expressions contain
// `await` calls inside an async arrow. Exercises three things at once:
//   1. JSX expression-container in an attribute value,
//   2. JSX expression-container in the children position,
//   3. `await` inside a nested async arrow function inside a JSX child.
const UI = async () => (
  <section title={await loadTitle()}>
    {items.map(async (x) => <Row key={x.id} label={await x.label()} />)}
  </section>
);
