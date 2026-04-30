// Realistic JSX form-component pattern. Exercises shapes 009 doesn't:
//   * computed JSXAttribute values via JSXExpressionContainer holding
//     an ObjectExpression and a TemplateLiteral mixed
//   * deeply-nested ternary inside a JSXExpressionContainer child
//     (JSX → expr → cond → JSX)
//   * a tag whose name is itself a member expression (`Form.Input`),
//     covering JSXMemberExpression in *both* opening and closing tags
//   * mixed text + interpolation children with whitespace at the seams
//   * a fragment used as the *value* of a JSXAttribute — legal but rare
//   * JSX child that is a function call returning JSX (HOC-style render
//     prop)
//
// Pure JSX, no TS. Parsed with --lang=jsx like the other spec/jsx fixtures.
function ContactForm({ onSubmit, fields, submitLabel }) {
  const handleSubmit = (e) => {
    e.preventDefault();
    onSubmit(Object.fromEntries(new FormData(e.target)));
  };

  return (
    <Form.Root
      onSubmit={handleSubmit}
      className="contact"
      style={{ padding: "1rem", display: "grid" }}
      data-meta={`fields=${fields.length} ts=${Date.now()}`}
    >
      <Form.Header tooltip={<>read the <a href="/help">help</a> page first</>}>
        Contact us
      </Form.Header>

      {fields.map((f) => (
        <Form.Field key={f.name} required={f.required}>
          <label htmlFor={f.name}>
            {f.label}
            {f.required ? <span className="req"> *</span> : null}
          </label>
          {f.type === "textarea" ? (
            <Form.Input.Textarea id={f.name} name={f.name} rows={f.rows ?? 4} />
          ) : f.type === "select" ? (
            <Form.Input.Select id={f.name} name={f.name}>
              {f.options.map((opt) => (
                <option key={opt.value} value={opt.value}>{opt.label}</option>
              ))}
            </Form.Input.Select>
          ) : (
            <Form.Input id={f.name} name={f.name} type={f.type} />
          )}
          {f.hint && <small>{f.hint}</small>}
        </Form.Field>
      ))}

      {/* render-prop child returning JSX */}
      {(() => (
        <Form.Footer>
          <button type="submit">{submitLabel}</button>
        </Form.Footer>
      ))()}
    </Form.Root>
  );
}
