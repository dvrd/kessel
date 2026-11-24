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
cp -R "$root/npm/kessel/types" "$root/npm/kessel/lsp" "$stage/main/"
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
node "$root/tests/verifiers/verify_lsp.js" --installed
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
const kessel = require('@dvrdlibs/kessel');
assert.deepEqual(kessel.isolatedDeclarationSync('lib.ts', 'export const id: number = 1;'),
  { output: 'export declare const id: number;\n', errors: [] });
const parsed = kessel.parseSync('test.ts', '/*🚀*/ const café: number = 1;');
assert.deepEqual(parsed.errors, []);
assert.equal(parsed.program.body[0].type, 'VariableDeclaration');
assert.equal(parsed.program.body[0].declarations[0].id.name, 'café');
assert.equal(parsed.program.body[0].declarations[0].id.typeAnnotation.typeAnnotation.type, 'TSNumberKeyword');
const declarations = kessel.parseSync('exports.ts', 'export interface Item {} export type Name = string;');
assert.deepEqual(declarations.errors, []);
assert.deepEqual(declarations.program.body.map(s => s.declaration.type),
  ['TSInterfaceDeclaration', 'TSTypeAliasDeclaration']);
const boundary = kessel.parseSync('boundary.mjs', 'export default function () {}(value);');
assert.deepEqual(boundary.errors, []);
assert.deepEqual(boundary.program.body.map(node => node.type), ['ExportDefaultDeclaration', 'ExpressionStatement']);
assert.equal(boundary.program.body[1].expression.name, 'value');
const moduleSource = '/*🚀*/ export default function café() {}';
const exported = kessel.parseSync('name.mjs', moduleSource).program.body[0].declaration;
assert.equal(exported.type, 'FunctionDeclaration');
assert.equal(Buffer.from(moduleSource).subarray(exported.id.start, exported.id.end).toString(), 'café');
const branches = 'function f(x, y) { if (x) { return 1; } else if (y) return 2; else log(); }';
const warnings = kessel.lintSync('branches.js', branches, { rules: { 'no-else-return': 'error' } }).diagnostics;
assert.deepEqual(warnings.filter(d => d.code === 'L4053').map(d => branches.slice(d.start, d.end).trim()), ['else']);
const fields = kessel.parseSync('fields.ts', 'class C { declare static x: number; declare = 2; }');
assert.deepEqual(fields.errors, []);
assert.deepEqual(fields.program.body[0].body.body.map(m => [m.type, m.static, m.declare]), [
  ['PropertyDefinition', true, true], ['PropertyDefinition', false, undefined],
]);
assert.deepEqual(kessel.lintSync('input.js', 'debugger;', { fix: true }), { diagnostics: [], output: '' });
const equality = kessel.lintSync('input.js', 'void (a == b); void (1 == 2);', {
  rules: { eqeqeq: ['error', 'smart'] },
});
assert.deepEqual(equality.diagnostics.filter(d => d.code === 'L1003').map(d => [d.start, d.end]), [[8, 10]]);
assert.deepEqual(kessel.lintSync('input.ts', 'let x: number=1;', {
  rules: { 'prefer-const': ['error', { destructuring: 'all' }] }, fix: true,
}), { output: 'const x: number=1;', diagnostics: [] });
assert.equal(kessel.scanModuleSync('export const a = 1;').exports[0].name, 'a');
const logging = kessel.lintSync('logger.js', 'console.log(1); console.warn(2);', {
  rules: { 'no-console': ['error', { allow: ['warn'] }] }, fixSuggestions: true,
});
assert.deepEqual(logging, { output: ' console.warn(2);', diagnostics: [] });
assert.equal(kessel.parseRegExpSync('a+', 'gu').nodes[1].kind, 'Pattern');
assert.deepEqual(kessel.resolveModuleSync('node:fs', 'test.js'), { kind: 'builtin', path: 'node:fs' });
fs.mkdirSync('generated');
fs.writeFileSync('generated/styles.d.css.ts', 'export {};');
fs.writeFileSync('virtual.json', JSON.stringify({compilerOptions: {rootDirs: ['.', 'generated']}}));
assert.equal(kessel.resolveModuleSync('./styles.css', 'app.ts', {tsconfig: 'virtual.json'}).path,
  fs.realpathSync('generated/styles.d.css.ts'));
fs.writeFileSync('entry.ts', '');
const entry = kessel.resolveModuleSync('.', 'test.js', { mode: 'require', extensions: ['.ts'], mainFiles: ['entry'] });
assert.equal(entry.path, fs.realpathSync('entry.ts'));
assert.equal(kessel.resolveModuleSync('./entry.js', 'test.js', { extensionAlias: { '.js': ['.ts', '.js'] } }).path, entry.path);
assert.equal(kessel.resolveModuleSync('entry.ts', 'test.js', { modules: ['.'] }).path, entry.path);
fs.mkdirSync('manifest-fields');
fs.writeFileSync('manifest-fields/package.json', JSON.stringify({
  name: 'with-fields', tooling: { public: './entry.js', private: { '#entry': 'with-fields' } },
}));
fs.writeFileSync('manifest-fields/entry.js', '');
const customEntry = kessel.resolveModuleSync('#entry', 'manifest-fields/entry.js', {
  exportsFields: [['tooling', 'public']], importsFields: ['imports', ['tooling', 'private']],
});
assert.equal(customEntry.path, fs.realpathSync('manifest-fields/entry.js'));
assert.equal(kessel.formatSync('config.ts', 'export const x={ports:[80,443]} as const;'),
  'export const x = { ports: [80, 443] } as const;\n');
assert.equal(kessel.formatSync('entry.ts', "import{type A,B}from'm';", { printWidth: 12 }),
  'import {\n  type A,\n  B,\n} from "m";\n');
const transformed = kessel.transformSync('entry.tsx', 'globalThis.result = <tag prop="&amp;" />;', {
  jsx: { runtime: 'classic', pragma: 'h' },
});
assert.deepEqual(transformed.errors, []);
const state = {};
new Function('globalThis', 'h', transformed.code)(state, (...args) => args);
assert.deepEqual(state.result, ['tag', { prop: '&' }]);
const automatic = kessel.transformSync('entry.tsx', 'globalThis.result = <tag key="id"/>;', {
  jsx: { runtime: 'automatic', importSource: 'layout' },
});
assert.deepEqual(automatic.errors, []);
new Function('globalThis', 'require', automatic.code)(state, specifier => {
  assert.equal(specifier, 'layout/jsx-runtime');
  return { jsx: (...args) => args };
});
assert.deepEqual(state.result, ['tag', {}, 'id']);
const dev = kessel.transformSync('view.tsx', 'globalThis.result = <tag/>;', {
  jsx: { runtime: 'automatic', development: true },
});
assert.deepEqual(dev.errors, []);
new Function('globalThis', 'require', dev.code)(state, specifier => {
  assert.equal(specifier, 'react/jsx-dev-runtime');
  return { jsxDEV: (tag, props, key, multiple, source) => source };
});
assert.deepEqual(state.result, { fileName: 'view.tsx', lineNumber: 1, columnNumber: 21 });
const enums = kessel.transformSync('size.ts', 'const enum E { X = 4 }; globalThis.result = E.X;', {
  typescript: { optimizeConstEnums: true },
});
assert.deepEqual(enums.errors, []);
assert.doesNotMatch(enums.code, /var E/);
new Function('globalThis', enums.code)(state);
assert.equal(state.result, 4);
const globals = kessel.transformSync('mode.cjs', 'return [process.env.MODE, (process => process.env.MODE)({env:{MODE:"local"}})];', {
  define: {'process.env.MODE': '"packed"'},
});
assert.deepEqual(globals.errors, []);
assert.deepEqual(new Function(globals.code)(), ['packed', 'local']);
const resources = kessel.transformSync('close.cjs',
  'function run(log) { using r = { [Symbol.dispose || Symbol.for("Symbol.dispose")]() { log.push(2); } }; log.push(1); }',
  { explicitResourceManagement: true });
assert.deepEqual(resources.errors, []);
const events = [];
new Function('log', resources.code + ';run(log);')(events);
assert.deepEqual(events, [1, 2]);
NODE
node --input-type=module - <<'NODE'
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
createRequire(require.resolve('@dvrdlibs/kessel'))('koffi').load(null);
const { parseAsync, scanModuleSync, minifySync } = await import('@dvrdlibs/kessel');
const optimized = minifySync('unsaved.js', 'function sum(longInput){return longInput + 6 * 7;}', {sourceMap: true});
assert.deepEqual(optimized.errors, []);
assert.equal(optimized.code, 'function sum(a){return a+42;}');
assert.deepEqual(optimized.map.sources, ['unsaved.js']);
const element = minifySync('unsaved.jsx', 'function view(factory, LongItem){return <LongItem/>;}', {
  jsx: { pragma: 'factory.render' },
});
assert.deepEqual(element.errors, []);
assert.match(element.code, /view\(factory,([A-Z$_][\w$]*)\)\{return <\1\s*\/>/);

assert.equal(scanModuleSync("import('async');").dependencies[0].name, 'async');
const typed = await parseAsync('element.tsx', 'const element = <View<string> />;');
assert.deepEqual(typed.errors, []);
assert.equal(typed.program.body[0].declarations[0].init.openingElement.typeArguments.params[0].type, 'TSStringKeyword');
const signature = await parseAsync('api.ts',
  'export type Read = ([entry]?: [typeof import("pkg", {with: {type: "json"}}).A.B]) => void;');
assert.deepEqual(signature.errors, []);
const [param] = signature.program.body[0].declaration.typeAnnotation.params;
assert.equal(param.optional, true);
assert.equal(param.elements[0].name, 'entry');
const [query] = param.typeAnnotation.typeAnnotation.elementTypes;
assert.equal(query.type, 'TSTypeQuery');
assert.equal(query.exprName.qualifier.right.name, 'B');
assert.equal(query.exprName.options.properties[0].value.properties[0].value.value, 'json');
const source = '/*🚀*/ const element = ' + '['.repeat(64) + '<main />' + ']'.repeat(64) + ';';
const parsed = await parseAsync('test.tsx', source);
assert.deepEqual(parsed.errors, []);
let expression = parsed.program.body[0].declarations[0].init;
for (let depth = 0; depth < 64; depth++) {
  assert.equal(expression.type, 'ArrayExpression');
  expression = expression.elements[0];
}
assert.equal(expression.type, 'JSXElement');
assert.equal(expression.openingElement.name.name, 'main');
NODE
cat > smoke.mts <<'TS'
import {
  codegen, formatSync, lintSync, parseAsync, parseSync, parseRegExpSync, resolveModuleSync,
  scanModuleSync, isolatedDeclarationSync, transformSync, minifySync, type ParseResult, type ModuleScanResult
} from '@dvrdlibs/kessel';
const result: ParseResult = parseSync('test.ts', 'const value: number = 1;');
await parseAsync('test.js', 'const value = 1;');
codegen('const value = 1;', { filename: 'test.js', sourceMap: true });
minifySync('sum.js', '6 * 7', { compress: true, mangle: false, sourceMap: true }).map?.mappings;
minifySync('view.jsx', 'const App = () => <div/>', { jsx: { pragma: 'ui.create', pragmaFrag: 'ui.Fragment' } });
// @ts-expect-error Minification pass selectors are booleans.
minifySync('sum.js', '6 * 7', { mangle: 'all' });
const fixed: string | undefined = lintSync('test.js', 'debugger;', { fix: true, fixDangerously: false, fixSuggestions: false }).output;
lintSync('unsaved.ts', 'let n = 1;', { workspaceRoot: '/workspace' });
const singleEdit = lintSync('example.ts', 'debugger;', { includeFixes: true }).diagnostics[0]?.fix;
const replacement: string | undefined = singleEdit?.text;
lintSync('test.ts', 'let x=1;', { fix: true, rules: { 'prefer-const': ['warn', { destructuring: 'all', ignoreReadBeforeAssign: true }] } });
lintSync('logger.js', '', { rules: { 'no-console': ['warn', { allow: ['warn'] as const }] } });
lintSync('getter.js', '', { rules: { 'getter-return': ['warn', { allowImplicit: true }] } });
lintSync('switch.js', '', { rules: { 'no-fallthrough': ['warn', { allowEmptyCase: true, commentPattern: 'omitted', reportUnusedFallthroughComment: true }] } });
// @ts-expect-error Empty-case handling accepts a boolean.
lintSync('switch.js', '', { rules: { 'no-fallthrough': ['warn', { allowEmptyCase: 'yes' }] } });
// @ts-expect-error Getter options require a boolean.
lintSync('getter.js', '', { rules: { 'getter-return': ['warn', { allowImplicit: 'yes' }] } });
// @ts-expect-error Console method names must be strings.
lintSync('logger.js', '', { rules: { 'no-console': ['warn', { allow: [1] }] } });
// @ts-expect-error Equality modes belong to eqeqeq.
lintSync('test.js', '', { rules: { 'prefer-const': ['warn', 'smart'] } });
// @ts-expect-error Destructuring options belong to prefer-const.
lintSync('test.js', '', { rules: { eqeqeq: ['warn', { destructuring: 'all' }] } });
lintSync('test.js', '// oxlint-disable', { reportUnusedDisableDirectives: 'warn', rules: { eqeqeq: ['error','always',{null:'ignore'}] } });
const module: ModuleScanResult = scanModuleSync('export const a = 1;');
module.exports[0].local_span?.start;
parseRegExpSync('a+', 'u').nodes[0].span;
resolveModuleSync('x', 'test.js', { conditions: ['development'], aliases: [{ name: 'x', target: 'y' }] }).kind;
resolveModuleSync('.', 'test.js', { mode: 'require', extensions: ['.ts'], mainFiles: ['entry'] }).path;
resolveModuleSync('./entry.js', 'test.js', { extensionAlias: { '.js': ['.ts', '.js'] } }).path;
resolveModuleSync('entry.ts', 'test.js', { modules: ['vendor', 'node_modules'], mainFields: 'module' }).path;
resolveModuleSync('#entry', 'test.js', { exportsFields: [['tooling', 'public']], importsFields: ['imports'] }).path;
const declaration: string = isolatedDeclarationSync('api.ts', 'export const n = 1;').output;
const formatted: string = formatSync('entry.ts', '', { singleQuote: true, trailingComma: 'es5', endOfLine: 'auto' });
transformSync('file.tsx', '<div/>', { jsx: { runtime: 'classic', pure: false }, sourceMap: true }).map?.mappings;
transformSync('file.tsx', '<div/>', { jsx: { runtime: 'automatic', importSource: 'layout', development: true } }).code;
transformSync('mode.ts', 'MODE', { define: {MODE: '"packed"'} }).code;
// @ts-expect-error Define values contain JavaScript source text.
transformSync('mode.ts', 'MODE', { define: {MODE: false} });
transformSync('size.ts', 'const enum Size { A }', { typescript: { optimizeConstEnums: true } }).code;
transformSync('close.mjs', 'await using r = null;', { explicitResourceManagement: true }).code;
result.program.body;
TS
node node_modules/typescript/bin/tsc --noEmit --strict --module nodenext smoke.mts
echo "Packed install passed for $target on $(node --version)"
