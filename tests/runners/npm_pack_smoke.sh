#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
stage=$(mktemp -d "${TMPDIR:-/tmp}/kessel-pack.XXXXXX")
trap 'rm -rf -- "$stage"' EXIT
target=$(node -p 'process.platform + "-" + process.arch')
case "$target" in
  darwin-*) extension=dylib ;;
  linux-*) extension=so ;;
  win32-*) extension=dll ;;
  *) echo "Unsupported native package platform: $target" >&2; exit 1 ;;
esac

mkdir -p "$stage/main" "$stage/native" "$stage/consumer"
cp -R "$root/npm/kessel/types" "$stage/main/"
cp "$root/npm/kessel/"{package.json,index.js,async-fallback.js,parse-worker.js,binary-reader.js,visitor.js,format.js,README.md,CHANGELOG.md} "$stage/main/"
cp "$root/npm/platforms/$target/"{index.js,package.json} "$stage/native/"
cp "${KESSEL_PACKAGE_BINARY:-$root/bin/libkessel.$extension}" "$stage/native/libkessel.$extension"

cd "$stage"
node - <<'NODE'
const fs = require('node:fs');
const main = require('./main/package.json');
const native = require('./native/package.json');
const version = process.env.KESSEL_PACKAGE_VERSION || main.version;
main.version = native.version = version;
for (const dependency of Object.keys(main.optionalDependencies)) {
  main.optionalDependencies[dependency] = version;
}
fs.writeFileSync('main/package.json', JSON.stringify(main, null, 2));
fs.writeFileSync('native/package.json', JSON.stringify(native, null, 2));
NODE
main_tarball=$(npm pack --silent ./main)
native_tarball=$(npm pack --silent ./native)

cd consumer
npm install --no-audit --no-fund "../$main_tarball" "../$native_tarball" typescript@5.9.3
node - <<'NODE'
const assert = require('node:assert/strict');
const fs = require('node:fs');
const crypto = require('node:crypto');
const platform = `@dvrdlibs/kessel-${process.platform}-${process.arch}`;
const digest = file => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const native = require(platform);
const binary = `libkessel.${{win32: 'dll', darwin: 'dylib', linux: 'so'}[process.platform]}`;
assert.equal(digest(native), digest(`../native/${binary}`));
const installed = fs.readdirSync('node_modules/@dvrdlibs').sort();
assert.deepEqual(installed, ['kessel', platform.split('/')[1]]);
const parsed = require('@dvrdlibs/kessel').parseSync('test.ts', 'const value: number = 1;');
assert.deepEqual(parsed.errors, []);
assert.equal(parsed.program.body[0].type, 'VariableDeclaration');
const fields = kessel.parseSync('fields.ts', 'class C { declare static x: number; declare = 2; }');
assert.deepEqual(fields.errors, []);
assert.deepEqual(fields.program.body[0].body.body.map(m => [m.type, m.static, m.declare]), [
  ['PropertyDefinition', true, true], ['PropertyDefinition', false, undefined],
]);
NODE
node --input-type=module - <<'NODE'
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
createRequire(require.resolve('@dvrdlibs/kessel'))('koffi').load(null);
const { parseAsync } = await import('@dvrdlibs/kessel');
const source = 'const element = ' + '['.repeat(64) + '<main />' + ']'.repeat(64) + ';';
const parsed = await parseAsync('test.tsx', source);
assert.deepEqual(parsed.errors, []);
let expression = parsed.program.body[0].declarations[0].init;
for (let depth = 0; depth < 64; depth++) {
  assert.equal(expression.type, 'ArrayExpression');
  expression = expression.elements[0];
}
assert.equal(expression.type, 'JSXElement');
NODE
cat > smoke.mts <<'TS'
import { codegen, lintSync, parseAsync, parseSync, type ParseResult } from '@dvrdlibs/kessel';
const result: ParseResult = parseSync('test.ts', 'const value: number = 1;');
await parseAsync('test.js', 'const value = 1;');
codegen('const value = 1;', { filename: 'test.js', sourceMap: true });
lintSync('test.js', 'debugger;');
result.program.body;
TS
node node_modules/typescript/bin/tsc --noEmit --strict --module nodenext smoke.mts
echo "Packed install passed for $target on $(node --version)"
