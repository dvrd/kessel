// JSX attribute without value shorthand: `<input disabled />` has
// ESTree JSXAttribute.value === null, NOT a Literal(true).
const a = <input disabled />;
const b = <input readonly required />;
