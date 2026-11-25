'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const fixtures = [...require('../format/modules.json'), ...require('../format/data.json'),
  ...require('../format/statements.json'), ...require('../format/typescript.json')];
const { prettier_npm } = require('../../OXC_ORACLE.json');

const binary = process.env.KESSEL_BIN || path.resolve(__dirname, '../../bin/kessel');
const oracle = process.env.KESSEL_PRETTIER && require(process.env.KESSEL_PRETTIER);
const stage = fs.mkdtempSync(path.join(os.tmpdir(), 'kessel-fmt-'));
const file = path.join(stage, 'module.ts');
// Prettier's layout of a generic arrow function depends on the file name, so
// the reference formats under the name that Kessel is given.
const filepath = 'module.ts';

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
    if (oracle) assert.equal(await oracle.format(source, {parser, filepath, ...options}), expected, name);
    verify(name, source, options, expected);
  }
  if (oracle) {
    let comparisons = 0;
    for (const {name, source, parser} of fixtures) {
      for (const printWidth of [12, 20, 32, 48, 80]) {
        for (const style of [{}, {bracketSpacing:false, singleQuote:true}, {useTabs:true, trailingComma:'none'}]) {
          const options = {printWidth, ...style};
          const expected = await oracle.format(source, {parser, filepath, ...options});
          verify(name, source, options, expected);
          comparisons++;
        }
      }
    }
    console.log(`Matched the installed Prettier ${oracle.version} on ${comparisons} width and style combinations.`);
  }
  // Statements that the printers do not cover keep their original text:
  // comments inside an expression or a type, ignore directives, decorators in
  // front of `export` or on a class expression, JSX syntax, and the few shapes
  // whose Prettier layout would regroup operands or depend on parentheses
  // that the parser does not record.
  const preserved = [
    'const flags={ enabled: /* configured */ true };',
    '// prettier-ignore\nconst data = [  [1,  2], [3,4] ];',
    '// prettier-ignore\nimport { x,  y }from\'p\';',
    '/* prettier-ignore */\n/* reason */\nexport {x,  y}from\'p\';',
    'import { x, /* grouped names */ y }from\'p\';',
    'import "line\\\ncontinuation";',
    'function  f( a /* first */ ){ return  a }',
    'const  total = first + /* why */ second;',
    'var  count /* none */;',
    'type  Pair<T>=[T, /* second */ T];',
    'function  union( a:number| /* or */ string ) { return a }',
    'const  sure = value as /* really */ Shape<number>;',
    '@decorated  export  class  Marked {}',
    'const  Marked = @decorated  class {};',
    '@Component({ template:`<p></p>` })  class  View {}',
    'type  Only = | Shape;',
    'const  nested = a||(b||c);',
    'export  default  (function(){ return 1 });',
    'const  styles = css`color:red;`;',
    'register( { "ключ": 1 } );',
  ];
  for (const source of preserved) verify('preserve original spelling', source, {}, source);
  // Prettier's layout of this statement changes when it is formatted a second
  // time: the object it expands then counts as written expanded, and the call
  // chain stays on one line. Output that is not stable is not emitted.
  const unstable = 'x={args:s.array().items(s.string(),s.object({name:s.string().pattern(n.nameRx).required(),ref:s.boolean(),assert:s.alternatives([s.function(),s.object().schema()]).conditional("ref",{is:!0,then:s.required()})}))};';
  if (oracle) {
    const once = await oracle.format(unstable, {parser: 'typescript'});
    assert.notEqual(await oracle.format(once, {parser: 'typescript'}), once);
  }
  verify('preserve a statement with no stable layout', unstable, {}, unstable);
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
  // Line breaks inside a template literal follow the chosen line ending,
  // as they do in Prettier. A template's raw value never contains a CR.
  const tagged = 'const text = tag`first\nsecond\r\nlast`;\r\n';
  const taggedExpected = 'const text = tag`first\r\nsecond\r\nlast`;\r\nimport "pkg";\r\n';
  if (oracle) {
    assert.equal(await oracle.format(tagged + "import'pkg';", {parser:'typescript', endOfLine:'auto'}), taggedExpected);
  }
  verify('template lines and generated module lines', tagged + "import'pkg';", {endOfLine:'auto'}, taggedExpected);
  // Comments around top-level statements take Prettier's spacing. A comment
  // beside a statement that keeps its text keeps its own text too.
  const around = "/**\n    * Header.\n  */\n\n\n   // leading\nconst    a=1;    /* one */    // two\nimport{b}from'm';   // public\nconst  kept = a||(b||c);   // kept\n// last";
  const aroundExpected = '/**\n * Header.\n */\n\n// leading\nconst a = 1; /* one */ // two\nimport { b } from "m";   // public\nconst  kept = a||(b||c);   // kept\n// last';
  verify('comments around top-level statements', around, {}, aroundExpected);
  if (oracle) {
    const plain = around.replace("const  kept = a||(b||c);   // kept\n", '').replace("import{b}from'm';   // public\n", '');
    verify('comments around top-level statements', plain, {}, await oracle.format(plain, {parser: 'typescript'}));
  }
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
