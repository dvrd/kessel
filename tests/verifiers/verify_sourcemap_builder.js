// Round trip for the public Source Map v3 builder (src/sourcemap_builder.odin).
//
// Goal: prove that a map built through the Odin API is read back correctly
// by an independent, widely used decoder.
//
// Method: tests/library/sourcemap_roundtrip is an Odin program that imports
// Kessel as a package, the way a downstream compiler does, and prints the
// map it built plus the mappings it put in. This script compiles and runs
// it, decodes the map with `source-map-js`, and requires:
//   * every decoded mapping to equal the corresponding input mapping
//     (generated position, source, original position, name), in order;
//   * `originalPositionFor` to resolve each mapped generated position;
//   * `file`, `sourceRoot`, `sources`, `sourcesContent` and `names` to
//     carry what was registered.
// Run with NODE_PATH=bench/node_modules.
const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { SourceMapConsumer } = require('source-map-js');

const root = path.join(__dirname, '..', '..');
const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'kessel-sourcemap-builder-'));
process.on('exit', () => fs.rmSync(scratch, { recursive: true, force: true }));

const program = path.join(scratch, 'sourcemap_roundtrip');
execFileSync('odin', ['build', 'tests/library/sourcemap_roundtrip', '-out:' + program, '-o:none'],
  { cwd: root, stdio: ['ignore', 'inherit', 'inherit'] });
const { map, content, expected } = JSON.parse(execFileSync(program, { encoding: 'utf8' }));

assert.equal(map.version, 3);
assert.equal(map.file, 'out/bundle.js');
assert.equal(map.sourceRoot, '/project');
assert.deepEqual(map.sources, ['src/a.jsx', 'src/b.js']);
assert.deepEqual(map.sourcesContent, [content, null]);
// Names are deduplicated, in order of first use.
assert.deepEqual(map.names, ['App', 'render', 'useState']);
assert.equal(typeof map.mappings, 'string');

const consumer = new SourceMapConsumer(map);
const decoded = [];
consumer.eachMapping(mapping => {
  // source-map-js reports 1-based lines; the builder and the format are 0-based.
  const mapped = mapping.source !== null;
  decoded.push([
    mapping.generatedLine - 1,
    mapping.generatedColumn,
    mapped ? mapping.source.replace('/project/', '') : '',
    mapped ? mapping.originalLine - 1 : 0,
    mapped ? mapping.originalColumn : 0,
    mapping.name ?? '',
  ]);
}, null, SourceMapConsumer.GENERATED_ORDER);
assert.deepEqual(decoded, expected);
assert.equal(decoded.length, 10);

let resolved = 0;
for (const [line, column, source, originalLine, originalColumn, name] of expected) {
  if (source === '') continue;
  const original = consumer.originalPositionFor({ line: line + 1, column });
  assert.equal(original.source, '/project/' + source);
  assert.equal(original.line, originalLine + 1);
  assert.equal(original.column, originalColumn);
  assert.equal(original.name, name === '' ? null : name);
  resolved++;
}
assert.equal(resolved, 8);
assert.equal(consumer.sourceContentFor('/project/src/a.jsx'), content);

console.log(`verify_sourcemap_builder: ${decoded.length} mappings round-trip ` +
  'through source-map-js');
