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

  await page.setViewportSize({width: 375, height: 740});
  assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth));
  const panes = await page.locator('.workspace section').evaluateAll(nodes => nodes.map(node => node.getBoundingClientRect().top));
  assert.ok(panes[1] > panes[0]);
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
  console.log('Headless Chromium passed TSX parsing, diagnostics, formatting, complete AST and source downloads, limit recovery and mobile layout.');
} finally {
  await browser?.close();
  if (server.listening) await new Promise(resolve => server.close(resolve));
}
