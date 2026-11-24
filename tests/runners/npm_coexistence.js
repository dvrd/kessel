'use strict';

const assert = require('node:assert/strict');

async function main() {
  const bindings = process.argv.slice(2);
  assert.equal(bindings.length, 2);

  const source = 'const element: JSX.Element = <div />;';
  for (const binding of bindings) {
    const { parseSync, parseAsync, lintSync, codegen, scanModuleSync, parseRegExpSync, resolveModuleSync } = require(binding);
    const sync = parseSync('coexist.tsx', source);
    const async = await parseAsync('coexist.tsx', source);
    assert.deepEqual(sync.errors, []);
    assert.equal(sync.program.body[0].declarations[0].init.type, 'JSXElement');
    assert.deepEqual(async, sync);

    const linted = lintSync('coexist.js', 'debugger;');
    assert.ok(linted.diagnostics.some(diagnostic => diagnostic.code === 'L2001'));
    const generated = codegen(source, { filename: 'coexist.tsx', sourceMap: true });
    assert.deepEqual(generated.errors, []);
    assert.ok(generated.code.includes('<div'));
    assert.equal(generated.map.version, 3);
    if (typeof scanModuleSync === 'function') {
      assert.deepEqual(scanModuleSync("import('other');").dependencies.map(item => item.name), ['other']);
      assert.equal(parseRegExpSync('a+').nodes[1].kind, 'Pattern');
      assert.deepEqual(resolveModuleSync('node:fs', 'coexist.js'), {kind: 'builtin', path: 'node:fs'});
    }
    console.log(`${binding} passed`);
  }
}

main().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
