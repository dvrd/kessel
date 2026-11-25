'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { SourceMap } = require('node:module');

module.exports = function checkEnums(binary, temp, run, oracle) {
  const file = path.join(__dirname, '../transform/typescript/const-enums.ts');
  const source = fs.readFileSync(file, 'utf8');
  function execute(code) {
    return run(process.execPath, ['--input-type=module'], code);
  }
  for (const optimizeConstEnums of [false, true]) {
    const options = optimizeConstEnums ? ['--optimize-const-enums'] : [];
    let expected;
    if (oracle) {
      const reference = oracle.transformSync(file, source, { typescript: { optimizeConstEnums } });
      assert.deepEqual(reference.errors, []);
      expected = execute(reference.code);
    }
    for (const flags of [[], ['--minified']]) {
      const code = run(binary, ['transform', file, ...options, ...flags]);
      const data = execute(code + '\nif (Public.Count !== 3) throw Error("missing exported enum");');
      if (oracle) assert.equal(data, expected);
      assert.equal(/\bvar Flags\b/.test(code), !optimizeConstEnums);
      assert.match(code, /export var Public\b/);
    }
  }
  const fallback = path.join(temp, 'enum-uses.ts');
  fs.writeFileSync(fallback, [
    'const enum Shared { A = 3 } export { Shared as alias };',
    'const enum Mutated { A = 1 } Mutated.A++;',
    'const key = "A"; if (Shared[key] !== 3 || Mutated.A !== 2) throw Error("lost runtime use");',
    'let calls=0; const enum Partial { X = ++calls, Y = 5 };',
    'if (Partial.X !== 1 || Partial.Y !== 5 || calls !== 1) throw Error("changed initializer");',
    'const enum Numeric { Tiny=1e-7, S=""+Tiny+","+1e-6+","+1e21+","+(0.1+0.2), N=0/0, I=1/0, Z=-0 }',
    'if (Numeric.S !== "1e-7,0.000001,1e+21,0.30000000000000004" || !Number.isNaN(Numeric.N) ||',
    '    Numeric.I !== Infinity || !Object.is(Numeric.Z, -0)) throw Error("numeric constants");',
    'const enum Powers { A = 1 ** (1/0), B = (-1) ** (-1/0), C = 1 ** (0/0), D = (0/0) ** 0 }',
    'if (![Powers.A, Powers.B, Powers.C].every(Number.isNaN) || Powers.D !== 1) throw Error("exponentiation");',
    'const enum Named { [`text`] = 8, Next } if (Named.text !== 8 || Named.Next !== 9) throw Error("computed name");',
    'const enum OuterValue { Answer=42 } function readAnswer() { interface OuterValue {} return OuterValue.Answer; }',
    'if (readAnswer() !== 42) throw Error("interface hid a runtime enum");',
  ].join('\n'));
  for (const flags of [[], ['--minified']]) {
    const code = run(binary, ['transform', fallback, '--optimize-const-enums', ...flags]);
    assert.doesNotMatch(code, /\bOuterValue\b/);
    execute(code);
  }
  fs.writeFileSync(fallback, 'const enum Color { Red = "r" }\nexport const label = Color.Red;');
  const output = run(binary, ['transform', fallback, '--optimize-const-enums', '--sourcemap']);
  const [code, encoded] = output.split('//# sourceMappingURL=data:application/json;base64,');
  const prefix = code.slice(0, code.indexOf('("r")')).split('\n');
  const map = new SourceMap(JSON.parse(Buffer.from(encoded.trim(), 'base64')));
  const location = map.findEntry(prefix.length - 1, prefix.at(-1).length);
  assert.deepEqual([location.originalLine, location.originalColumn], [1, 'export const label = '.length]);
  const members = ['M0 = "x"'];
  for (let i = 1; i <= 18; i++) members.push(`M${i} = M${i-1} + M${i-1}`);
  fs.writeFileSync(fallback, 'const enum Size {' + members.join(',') +
    '} if (Size.M18.length !== 262144) throw Error("string growth fallback");');
  const bounded = run(binary, ['transform', fallback, '--optimize-const-enums']);
  assert.ok(bounded.length < 64 * 1024);
  execute(bounded);
  console.log('Const enum values, merged and shadowed scopes, exports, and runtime fallbacks passed.');
};
