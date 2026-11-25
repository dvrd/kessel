import assert from 'node:assert/strict';
import { once } from 'node:events';
import fs from 'node:fs/promises';
import http from 'node:http';
import { chromium } from 'playwright';

const assets = new Map([
  ['index.html', 'text/html'], ['style.css', 'text/css'], ['app.mjs', 'text/javascript'],
  ['worker.mjs', 'text/javascript'], ['parser.mjs', 'text/javascript'], ['kessel.wasm', 'application/wasm'],
]);
const directory = new URL('../bin/playground/', import.meta.url);
const requests = [];
let failFirstDownload = true;
const server = http.createServer(async (request, response) => {
  const name = request.url.slice(1) || 'index.html';
  requests.push(name);
  if (!assets.has(name)) { response.writeHead(404).end(); return; }
  if (name === 'kessel.wasm' && failFirstDownload) {
    failFirstDownload = false;
    response.writeHead(503).end();
    return;
  }
  try {
    const bytes = await fs.readFile(new URL(name, directory));
    response.writeHead(200, {'Content-Type': assets.get(name)}).end(bytes);
  } catch { response.writeHead(500).end(); }
});

async function downloadedTree(page) {
  const waiting = page.waitForEvent('download');
  await page.getByRole('link', {name: 'Download JSON'}).click();
  const download = await waiting;
  assert.equal(download.suggestedFilename(), 'kessel-ast.json');
  const chunks = [];
  for await (const chunk of await download.createReadStream()) chunks.push(chunk);
  return JSON.parse(Buffer.concat(chunks).toString('utf8'));
}

async function verify(page) {
  const ready = () => page.waitForFunction(() => document.getElementById('status').textContent.startsWith('Parsed.'));
  const source = page.getByRole('textbox', {name: 'Source'});
  const view = page.locator('#output');
  await page.goto('http://127.0.0.1:' + server.address().port);
  await page.getByRole('button', {name: 'Retry loading'}).click();
  await ready();
  const initial = JSON.parse(await view.textContent());
  assert.equal(initial.type, 'Program');
  assert.equal(initial.body[0].type, 'TSTypeAliasDeclaration');
  assert.deepEqual(await downloadedTree(page), initial);

  await page.getByRole('button', {name: 'Formatted', exact: true}).click();
  const formattedReady = () => page.waitForFunction(() => document.getElementById('status').textContent.startsWith('Formatted.'));
  const original = "import{one,two}from'./🚀';\nexport const config={ports:[80,443]} as const satisfies Project.Config;";
  await source.fill(original);
  await formattedReady();
  const expected = 'import { one, two } from "./🚀";\nexport const config = { ports: [80, 443] } as const satisfies Project.Config;\n';
  assert.equal(await view.textContent(), expected);
  const saved = page.waitForEvent('download');
  await page.getByRole('link', {name: 'Download source'}).click();
  const file = await saved;
  assert.equal(file.suggestedFilename(), 'formatted.tsx');
  assert.equal(await fs.readFile(await file.path(), 'utf8'), expected);
  assert.equal(await source.inputValue(), original);
  await source.fill('import {');
  await page.waitForFunction(() => !['Formatting…', 'Formatted.'].includes(document.getElementById('status').textContent));
  assert.equal(await page.getByRole('link', {name: 'Download source'}).count(), 0);
  const longSource = '/*' + 'x'.repeat(70000) + '*/\n' + "import'x';";
  await source.fill(longSource);
  await formattedReady();
  assert.equal((await view.textContent()).length, 65536);
  const fullSource = page.waitForEvent('download');
  await page.getByRole('link', {name: 'Download source'}).click();
  assert.equal(await fs.readFile(await (await fullSource).path(), 'utf8'),
    longSource.replace("import'x';", 'import "x";\n'));

  await source.fill('let café; let café;');
  await page.getByRole('button', {name: /^Diagnostics/}).click();
  await ready();
  assert.match(await view.textContent(), /already been declared/);
  assert.doesNotMatch(await view.textContent(), /undefined/);
  await source.fill('break;');
  await ready();
  const before = (await downloadedTree(page)).errors.length;
  await page.getByLabel('Semantic diagnostics').check();
  await ready();
  assert.ok((await downloadedTree(page)).errors.length > before);

  await page.getByRole('combobox', {name: 'Language'}).selectOption('jsx');
  await source.fill('const el = <i>🚀</i>;');
  await ready();
  assert.equal(await view.textContent(), 'No diagnostics.');
  await page.getByRole('button', {name: 'AST', exact: true}).click();
  assert.equal(JSON.parse(await view.textContent()).body[0].declarations[0].init.type, 'JSXElement');

  await source.fill(Array.from({length: 500}, (_, index) => 'const item' + index + ' = 1;').join('\n'));
  await ready();
  assert.equal((await view.textContent()).length, 65536);
  assert.equal((await downloadedTree(page)).body.length, 500);
  await source.fill('x'.repeat(262145));
  await page.waitForFunction(() => document.getElementById('status').textContent.includes('byte playground limit'));
  assert.equal(await page.getByRole('link', {name: 'Download JSON'}).count(), 0);
  await source.fill('const recovered = true;');
  await ready();
  assert.equal(JSON.parse(await view.textContent()).body[0].declarations[0].id.name, 'recovered');
  assert.equal(requests.filter(name => name === 'kessel.wasm').length, 2);

  await verifyTools(page);

  await page.setViewportSize({width: 375, height: 740});
  assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth));
  const panes = await page.locator('.workspace section').evaluateAll(nodes => nodes.map(node => node.getBoundingClientRect().top));
  assert.ok(panes[1] > panes[0]);
}

async function downloadedText(page, link, filename) {
  const waiting = page.waitForEvent('download');
  await page.getByRole('link', {name: link}).click();
  const download = await waiting;
  assert.equal(download.suggestedFilename(), filename);
  return fs.readFile(await download.path(), 'utf8');
}

// The Lint, JavaScript, Minified and Declarations views each run their tool
// in the worker on the text in the editor and offer the result for download.
async function verifyTools(page) {
  const source = page.getByRole('textbox', {name: 'Source'});
  const view = page.locator('#output');
  const status = text => page.waitForFunction(
    expected => document.getElementById('status').textContent.startsWith(expected), text);
  const show = name => page.getByRole('button', {name, exact: true}).click();
  await page.getByRole('combobox', {name: 'Language'}).selectOption('tsx');
  const component = 'type Props = { name?: string };\nexport const Greeting = ({ name }: Props): unknown => ' +
    '<b title="🚀">{name ?? "you"}</b>;\nexport function twice(value: number): number { return value * 2; }\n' +
    'debugger;\n';
  await source.fill(component);

  await show('Lint');
  await status('Linted.');
  assert.equal(await view.textContent(), "4:1  error  no-debugger  unexpected 'debugger' statement");
  assert.equal(await downloadedText(page, 'Download report', 'kessel-lint.txt'), await view.textContent());

  await show('JavaScript');
  await status('Transformed.');
  const modern = await view.textContent();
  assert.match(modern, /from "react\/jsx-runtime"/);
  assert.match(modern, /"title": "🚀", children: name \?\? "you"/);
  assert.doesNotMatch(modern, /Props|: number|: string|unknown/);
  assert.equal(await downloadedText(page, 'Download JavaScript', 'transformed.js'), modern);
  await page.getByRole('combobox', {name: 'Target'}).selectOption('es2015');
  await status('Transformed.');
  assert.match(await view.textContent(), /name !== null && name !== void 0 \? name : "you"/);
  await page.getByRole('combobox', {name: 'JSX'}).selectOption('classic');
  await status('Transformed.');
  assert.match(await view.textContent(), /React\.createElement\("b"/);
  await page.getByRole('combobox', {name: 'JSX'}).selectOption('preserve');
  await status('Transformed.');
  assert.match(await view.textContent(), /<b title="🚀">/);
  assert.equal(await downloadedText(page, 'Download JavaScript', 'transformed.jsx'), await view.textContent());

  await show('Declarations');
  await status('Declarations emitted.');
  const declarations = await view.textContent();
  assert.match(declarations, /export declare const Greeting: \(\{ name \}: Props\) => unknown;/);
  assert.match(declarations, /export declare function twice\(value: number\): number;/);
  assert.equal(await downloadedText(page, 'Download declarations', 'declarations.d.ts'), declarations);

  await page.getByRole('combobox', {name: 'Language'}).selectOption('js');
  await source.fill('export function total(firstValue, secondValue) {\n  if (false) { unreachable(); }\n' +
    '  return (firstValue + secondValue) * 2 ** 10; // 🚀\n}\n');
  await show('Minified');
  await status('Minified.');
  const minified = await view.textContent();
  // Same bytes as `kessel minify`, which prints no space after `return`.
  assert.match(minified, /^export function total\(([a-z]),([a-z])\)\{return\(\1\+\2\)\*1024\}$/);
  assert.equal(await downloadedText(page, 'Download minified', 'minified.js'), minified);

  // A declaration file needs TypeScript, and a tool that cannot run reports
  // why in the status line and offers nothing to download.
  await show('Declarations');
  await page.waitForFunction(() => document.getElementById('status').textContent.includes('requires a TypeScript source'));
  assert.equal(await page.getByRole('link', {name: 'Download declarations'}).count(), 0);
  await show('JavaScript');
  await source.fill('/*é*/ const = ;');
  await page.waitForFunction(() => document.getElementById('status').textContent.startsWith('1:14  '));
  assert.equal(await view.textContent(), '');
  assert.equal(await page.getByRole('link', {name: 'Download JavaScript'}).count(), 0);
  await show('Lint');
  await status('Linted.');
  assert.match(await view.textContent(), /^1:14  error  K\d{4}  /);

  // Regexp literals with the `u` flag once stopped the module.
  await source.fill('const tag = /(?<name>\\p{L}+)\\k<name>/u; debugger;');
  await status('Linted.');
  assert.match(await view.textContent(), /^1:\d+  error  no-debugger  /);
  await show('AST');
  await status('Parsed.');
  assert.equal(JSON.parse(await view.textContent()).body[0].declarations[0].init.regex.flags, 'u');
  await source.fill('const recovered = true;');
  await status('Parsed.');
}

let browser;
try {
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  browser = await chromium.launch({headless: true});
  const page = await browser.newPage({viewport: {width: 1100, height: 800}, acceptDownloads: true});
  const failures = [];
  page.on('pageerror', error => failures.push(error.message));
  await verify(page);
  assert.deepEqual(failures, []);
  console.log('Headless Chromium passed TSX parsing, diagnostics, formatting, lint, transform targets and JSX modes, ' +
    'minify, declarations, tool errors, complete downloads, limit recovery and mobile layout.');
} finally {
  await browser?.close();
  if (server.listening) await new Promise(resolve => server.close(resolve));
}
