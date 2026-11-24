// The worked library example, checked end to end against the references.
//
// Goal: keep tests/library/consumer \u2014 the program the README's "Odin
// package" section is drawn from \u2014 compiling, and prove that what it derives
// through the library API (hashbang, AST walk, entity-decoded attributes,
// UTF-16 positions, scope queries, source map) is right.
//
// Method: build and run the program on tests/library/consumer/input.jsx,
// which starts with a hashbang, mixes CRLF, LF and U+2028 line ends and has
// astral and two-byte characters before the JSX. Then derive the same facts
// independently in JavaScript:
//   * elements, their order and their tag positions from oxc-parser's AST
//     (its `start` is a UTF-16 offset; line and column are computed here);
//   * the enclosing function of each element from the same AST;
//   * decoded attribute values from @babel/parser, since the pinned
//     oxc-parser leaves entities undecoded;
//   * the source map by decoding it with source-map-js.
// Finally the Odin snippet in the README section is extracted, compiled and
// run, so the documentation cannot drift from the API.
// Run with NODE_PATH=bench/node_modules.
const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { parseSync } = require('oxc-parser');
const babel = require('@babel/parser');
const { SourceMapConsumer } = require('source-map-js');

const root = path.join(__dirname, '..', '..');
const input = path.join(root, 'tests', 'library', 'consumer', 'input.jsx');
const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'kessel-library-consumer-'));
process.on('exit', () => fs.rmSync(scratch, { recursive: true, force: true }));

const program = path.join(scratch, 'consumer');
execFileSync('odin', ['build', 'tests/library/consumer', '-out:' + program, '-o:none'],
  { cwd: root, stdio: ['ignore', 'inherit', 'inherit'] });
const result = JSON.parse(execFileSync(program, [input], { encoding: 'utf8' }));
const source = fs.readFileSync(input, 'utf8');

// 1-based line and 0-based UTF-16 column of a UTF-16 offset. A JavaScript
// string index is already a UTF-16 offset.
function position(offset) {
  let line = 1;
  let lineStart = 0;
  for (let index = 0; index < offset; index++) {
    const unit = source[index];
    const crlf = unit === '\r' && source[index + 1] === '\n';
    if (!crlf && (unit === '\n' || unit === '\r' || unit === '\u2028' || unit === '\u2029')) {
      line++;
      lineStart = index + 1;
    }
  }
  return [line, offset - lineStart];
}

// Elements in source order with the innermost function around each.
function collect(node, enclosing, out) {
  if (node === null || typeof node !== 'object') return;
  if (Array.isArray(node)) { for (const item of node) collect(item, enclosing, out); return; }
  let inner = enclosing;
  if (node.type === 'JSXElement' && node.openingElement.name.type === 'JSXIdentifier') {
    out.push({ name: node.openingElement.name, enclosing });
  }
  const functions = ['FunctionDeclaration', 'FunctionExpression', 'ArrowFunctionExpression'];
  if (functions.includes(node.type)) inner = node;
  for (const key of Object.keys(node)) collect(node[key], inner, out);
}

const reference = parseSync('input.jsx', source);
assert.deepEqual(reference.errors, []);
const expected = [];
collect(reference.program, null, expected);

assert.equal(result.status, 'Completed');
assert.equal(result.hashbang, reference.program.hashbang.value);
assert.equal(result.elements.length, expected.length);
assert.equal(result.elements.length, 4);

// Decoded string attributes, keyed by element order.
const decoded = [];
(function attributes(node) {
  if (node === null || typeof node !== 'object') return;
  if (Array.isArray(node)) { node.forEach(attributes); return; }
  if (node.type === 'JSXOpeningElement') {
    const values = {};
    for (const attribute of node.attributes) {
      if (attribute.type === 'JSXAttribute' && attribute.value?.type === 'StringLiteral') {
        values[attribute.name.name] = attribute.value.value;
      }
    }
    decoded.push(values);
  }
  for (const key of Object.keys(node)) if (key !== 'loc') attributes(node[key]);
})(babel.parse(source, { sourceType: 'module', plugins: ['jsx'] }).program);

const bindings = { Card: 'Import', b: 'none', Page: 'Function', footer: 'none' };
result.elements.forEach((element, index) => {
  const { name, enclosing } = expected[index];
  assert.equal(element.name, name.name);
  assert.deepEqual([element.line, element.column], position(name.start), `${name.name} position`);
  assert.equal(element.binding, bindings[name.name], `${name.name} binding`);
  const wanted = enclosing === null ? null : position(enclosing.start);
  assert.deepEqual(element.function, wanted, `${name.name} enclosing function`);
  assert.deepEqual(element.attributes, decoded[index], `${name.name} attributes`);
});
// The decoding is real: these differ from the source text.
assert.equal(result.elements[0].attributes.title, 'Tom & Jerry');
assert.equal(result.elements[0].attributes.lang, 'caf\u00e9 \u{1F600}');
assert.equal(result.elements[2].attributes.id, '<main>');

// The map: generated line N is element N, mapped to its tag name.
assert.deepEqual(result.map.sources, ['input.jsx']);
assert.deepEqual(result.map.sourcesContent, [source]);
const consumer = new SourceMapConsumer(result.map);
result.elements.forEach((element, index) => {
  const original = consumer.originalPositionFor({ line: index + 1, column: 0 });
  const [line, column] = position(expected[index].name.start);
  assert.deepEqual(
    [original.source, original.line, original.column, original.name],
    ['input.jsx', line, column, element.name],
  );
});

// The README's "Odin package" snippet must compile and run as written.
const readme = fs.readFileSync(path.join(root, 'README.md'), 'utf8');
const section = readme.slice(readme.indexOf('### Odin package'));
const fence = /```odin\n([\s\S]*?)```/.exec(section);
assert.ok(fence, 'README has an Odin snippet in the "Odin package" section');
const importLine = 'import kessel "path/to/kessel/src"';
assert.ok(fence[1].includes(importLine));
const snippetDir = path.join(scratch, 'readme_example');
fs.mkdirSync(snippetDir);
fs.writeFileSync(path.join(snippetDir, 'main.odin'), [
  'package main',
  'import "core:os"',
  // Odin has no absolute import paths; a collection stands in for the
  // reader's own path to the checkout.
  fence[1].replace(importLine, 'import kessel "kessel:src"'),
  'main :: proc() {',
  '    source := "#!/x\\nfunction f(p = 1) { return <b c=\\"&amp;\\">t{...xs}<i/></b>; }"',
  '    if !compile(source) { os.exit(1) }',
  '}',
].join('\n'));
const snippet = path.join(scratch, 'readme_example_bin');
const snippetBuild = ['build', snippetDir, '-out:' + snippet, '-o:none'];
snippetBuild.push('-collection:kessel=' + root);
execFileSync('odin', snippetBuild, { stdio: ['ignore', 'inherit', 'inherit'] });
execFileSync(snippet, { stdio: ['ignore', 'inherit', 'inherit'] });

console.log(`verify_library_consumer: ${result.elements.length} elements match oxc-parser, ` +
  'Babel and source-map-js; the README snippet compiles and runs');
