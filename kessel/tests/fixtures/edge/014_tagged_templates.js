// Tagged templates con interpolation
function sql(strings, ...values) {
  return { query: strings.join('?'), params: values };
}

const id = 42;
const name = 'test';
const query = sql`SELECT * FROM users WHERE id = ${id} AND name = ${name}`;

function styled(strings, ...values) {
  return strings.reduce((acc, str, i) => acc + str + (values[i] || ''), '');
}

const color = 'red';
const css = styled`
  color: ${color};
  font-size: ${16}px;
`;
