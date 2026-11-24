'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const fixtures = [...require('../format/modules.json'), ...require('../format/data.json')];
const { prettier_npm } = require('../../OXC_ORACLE.json');

const binary = process.env.KESSEL_BIN || path.resolve(__dirname, '../../bin/kessel');
const oracle = process.env.KESSEL_PRETTIER && require(process.env.KESSEL_PRETTIER);
const stage = fs.mkdtempSync(path.join(os.tmpdir(), 'kessel-fmt-'));
const file = path.join(stage, 'module.ts');

function run(source, options = {}) {
  const args = ['fmt', file];
  if (options.printWidth !== undefined) args.push('--print-width', String(options.printWidth));
  if (options.tabWidth !== undefined) args.push('--tab-width', String(options.tabWidth));
  if (options.singleQuote) args.push('--single-quote');
  if (options.useTabs) args.push('--use-tabs');
  if (options.bracketSpacing === false) args.push('--no-bracket-spacing');
  if (options.trailingComma) args.push('--trailing-comma', options.trailingComma);
  if (options.endOfLine) args.push('--end-of-line', options.endOfLine);
  fs.writeFileSync(file, source);
  const result = spawnSync(binary, args, {encoding: 'utf8'});
  if (result.error) throw result.error;
  assert.equal(fs.readFileSync(file, 'utf8'), source);
  return result;
}

function verify(name, source, options, expected) {
  for (const input of [source, expected]) {
    const result = run(input, options);
    assert.equal(result.status, 0, name + ' ' + result.stderr);
    assert.equal(result.stdout, expected, name);
  }
}

async function main() {
  if (oracle) assert.equal(oracle.version, prettier_npm);
  for (const {name, source, options, parser, expected} of fixtures) {
    if (oracle) assert.equal(await oracle.format(source, {parser, ...options}), expected, name);
    verify(name, source, options, expected);
  }
  if (oracle) {
    let comparisons = 0;
    for (const {name, source, parser} of fixtures) {
      for (const printWidth of [12, 20, 32, 48, 80]) {
        for (const style of [{}, {bracketSpacing:false, singleQuote:true}, {useTabs:true, trailingComma:'none'}]) {
          const options = {printWidth, ...style};
          const expected = await oracle.format(source, {parser, ...options});
          verify(name, source, options, expected);
          comparisons++;
        }
      }
    }
    console.log(`Matched the installed Prettier ${oracle.version} on ${comparisons} width and style combinations.`);
  }
  const preserved = [
    'const record={ first: 1, method() { return 2 } };',
    'export default { key : a + b };',
    'const flags={ enabled: /* configured */ true };',
    '// prettier-ignore\nconst data = [  [1,  2], [3,4] ];',
    'const [value] = [ 1 ];',
    'const first=[ 1 ], second={ foo: 2 };',
    '// prettier-ignore\nimport { x,  y }from\'p\';',
    '/* prettier-ignore */\n/* reason */\nexport {x,  y}from\'p\';',
    'import { x, /* grouped names */ y }from\'p\';',
    'export const   result = (a) => a +  3;',
    'import "line\\\ncontinuation";',
    'const el =  23; // comment at EOF',
    "'use strict';\nconst a = 1;",
  ];
  for (const source of preserved) verify('preserve original spelling', source, {}, source);
  // A long property name can open one more layout group inside the last data
  // container. Crossing the stack bound must preserve the whole statement.
  for (const depth of [254, 255]) {
    const arrays = '['.repeat(depth);
    const ends = ']'.repeat(depth);
    const source = 'const deep=' + arrays + '{longProperty:value}' + ends + ';';
    const expected = depth === 254
      ? 'const deep = ' + arrays + '{ longProperty: value }' + ends + ';\n'
      : source;
    verify('bounded nested data at ' + depth, source, {printWidth: 1000}, expected);
  }
  for (const [first, second, auto] of [
    ['\n', '\n', '\n'], ['\r', '\r', '\r'], ['\r\n', '\r\n', '\r\n'],
    ['\n', '\r\n', '\r\n'], ['\r', '\n', '\r'],
  ]) {
    const source = "import'a';" + first + "export*from'b';" + second + "import'c';";
    for (const [endOfLine, newline] of Object.entries({lf:'\n', cr:'\r', crlf:'\r\n', auto})) {
      const expected = ['import "a";', 'export * from "b";', 'import "c";', ''].join(newline);
      if (oracle) assert.equal(await oracle.format(source, {parser:'babel', endOfLine}), expected);
      verify('module line endings ' + endOfLine, source, {endOfLine}, expected);
    }
  }
  const tagged = 'const text = tag`first\nsecond\r\nlast`;\r\n';
  verify('raw template lines and generated module lines', tagged + "import'pkg';",
    {endOfLine:'auto'}, tagged + 'import "pkg";\r\n');
  verify('preserve comments and surrounding code',
    "const    a=1;\nimport{b}from'm'; // public\nexport const f=()=>  1;",
    {}, 'const    a=1;\nimport { b } from "m"; // public\nexport const f=()=>  1;');
  const malformed = run("import 'a';\nimport {");
  assert.equal(malformed.status, 1);
  assert.equal(malformed.stdout, '');
  assert.ok(malformed.stderr.includes(file));
  for (const options of [{printWidth:0}, {tabWidth:17}, {trailingComma:'bad'}, {endOfLine:'bad'}]) {
    const invalid = run("import 'a';", options);
    assert.equal(invalid.status, 2);
    assert.equal(invalid.stdout, '');
  }
  console.log(`Formatter passed ${fixtures.length} Prettier ${prettier_npm} fixtures, preservation, idempotence and error checks.`);
}

main().catch(error => { console.error(error); process.exitCode = 1; })
  .finally(() => fs.rmSync(stage, {recursive: true, force: true}));
