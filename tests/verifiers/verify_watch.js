'use strict';

const assert = require('node:assert/strict');
const { spawn, spawnSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { setTimeout: delay } = require('node:timers/promises');

const binary = path.resolve(process.argv[2] || path.join(__dirname, '../../bin/kessel'));
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'kessel-watch-'));
const env = { ...process.env, KESSEL_COLOR: '0' };

function once(cwd, args) {
  const result = spawnSync(binary, args, { cwd, env, encoding: 'utf8', timeout: 15000 });
  if (result.error) throw result.error;
  return result;
}

// Pipes can deliver stdout and stderr in either order. Compare each stream to
// the native one-shot command, and fail if a save produces an extra run.
async function withWatch(cwd, args, test, structured = false) {
  const child = spawn(binary, [...args, '--watch'], { cwd, env, stdio: ['ignore', 'pipe', 'pipe'] });
  let stdout = '', stderr = '', expectedOut = '', expectedErr = '';
  let ended = false, spawnError;
  child.stdout.setEncoding('utf8').on('data', data => { stdout += data; });
  child.stderr.setEncoding('utf8').on('data', data => { stderr += data; });
  child.on('error', error => { spawnError = error; });
  const closed = new Promise(resolve => child.once('close', () => { ended = true; resolve(); }));

  async function expect(result = once(cwd, args)) {
    expectedOut += result.stdout;
    expectedErr += result.stderr;
    if (!structured) expectedErr += `watch: run finished (exit ${result.status}), waiting for changes\n`;
    const limit = Date.now() + 15000;
    while (stdout.length < expectedOut.length || stderr.length < expectedErr.length) {
      if (spawnError) throw spawnError;
      assert.ok(!ended && Date.now() < limit,
        `waiting for ${args[0]}\nstdout: ${stdout}\nstderr: ${stderr}\nexpected: ${expectedOut}\n${expectedErr}`);
      await delay(15);
    }
    assert.equal(stdout, expectedOut);
    assert.equal(stderr, expectedErr);
  }

  async function idle() {
    await delay(450);
    assert.equal(stdout, expectedOut);
    assert.equal(stderr, expectedErr);
    assert.equal(ended, false);
  }

  try {
    await test(expect, idle);
  } finally {
    if (!ended) child.kill('SIGINT');
    const timeout = setTimeout(() => child.kill('SIGKILL'), 2000);
    try { await closed; } finally { clearTimeout(timeout); }
  }
}

async function main() {
  const file = path.join(root, 'source file.ts');
  const fileName = path.basename(file);
  fs.writeFileSync(file, "import{a,b}from'a';");
  await withWatch(root, ['fmt', '--print-width', '16', '--single-quote', fileName], async (expect, idle) => {
    await expect();
    // Replace the file at the same path with a same-size revision.
    const replacement = file + '.new';
    fs.writeFileSync(replacement, "import{c,d}from'b';");
    const { atime, mtime } = fs.statSync(file);
    fs.utimesSync(replacement, atime, mtime);
    fs.renameSync(replacement, file);
    await expect();
    fs.unlinkSync(file);
    await expect();
    fs.writeFileSync(file, 'import {');
    await expect();
    fs.writeFileSync(file, "import{}from'restored';");
    await expect();
    assert.equal(fs.readFileSync(file, 'utf8'), "import{}from'restored';");
    await idle();
  });

  const jsx = path.join(root, 'view.tsx');
  fs.writeFileSync(jsx, 'export const view: any = <div/>;');
  await withWatch(root, ['transform', 'view.tsx', '--jsx=classic', '--minified'], async (expect, idle) => {
    await expect();
    fs.writeFileSync(jsx, 'export const view = <;');
    await expect();
    for (const tag of ['span', 'div', 'section']) fs.writeFileSync(jsx, `export const view = <${tag}/>;`);
    await expect();
    await idle();
  });

  const nested = path.join(root, 'nested');
  fs.mkdirSync(nested);
  fs.writeFileSync(path.join(root, 'a.js'), 'debugger;');
  fs.writeFileSync(path.join(nested, 'b.js'), '');
  const config = path.join(root, 'kessel.lint.json');
  const inherited = path.join(root, 'base settings.json');
  const nestedConfig = path.join(nested, '.oxlintrc.json');
  const configText = level => JSON.stringify({rules:{'no-debugger':level}});
  await withWatch(root, ['lint', '--format', 'json', 'a.js', 'nested/b.js'], async (expect, idle) => {
    await expect();
    fs.writeFileSync(path.join(nested, 'b.js'), 'debugger;');
    await expect();
    fs.writeFileSync(config, JSON.stringify({extends:'./base settings.json'}));
    await expect();
    fs.writeFileSync(inherited, configText('off'));
    await expect();
    fs.writeFileSync(inherited, '{bad');
    await expect();
    fs.writeFileSync(inherited, configText('error'));
    await expect();
    fs.writeFileSync(nestedConfig, configText('off'));
    await expect();
    fs.unlinkSync(nestedConfig);
    await expect();
    fs.writeFileSync(config, configText('off'));
    await expect();
    fs.writeFileSync(inherited, configText('warn'));
    await idle();
  }, true);

  const explicitConfig = path.join(root, 'settings with spaces.json');
  await withWatch(root, ['lint', '-c', path.basename(explicitConfig), 'a.js', '--format=json'],
    async expect => {
      await expect();
      fs.writeFileSync(explicitConfig, configText('error'));
      await expect();
      fs.writeFileSync(explicitConfig, configText('off'));
      await expect();
    }, true);

  const fix = path.join(root, 'fix.js');
  fs.writeFileSync(fix, "debugger;\nsave();");
  await withWatch(root, ['lint', '--fix', '--config', 'base settings.json', '--rule', 'no-debugger:error', 'fix.js'],
    async (expect, idle) => {
      const clean = {stdout:'', stderr:'', status:0};
      await expect(clean);
      assert.ok(!fs.readFileSync(fix, 'utf8').includes('debugger'));
      await idle();
      fs.writeFileSync(fix, 'debugger;\nnext();');
      await expect(clean);
      assert.match(fs.readFileSync(fix, 'utf8'), /next\(\)/);
      assert.ok(!fs.readFileSync(fix, 'utf8').includes('debugger'));
      await idle();
    });

  for (const command of ['lint', 'fmt', 'transform']) {
    assert.notEqual(once(root, [command, '--watch']).status, 0);
  }
  assert.equal(once(root, ['lint', '--list-rules', '--watch']).status, 2);
  console.log('Watch mode passed for lint, fmt and transform, including config reload, atomic saves, error recovery and autofix.');
}

main().catch(error => { console.error(error); process.exitCode = 1; })
  .finally(() => fs.rmSync(root, {recursive:true, force:true}));
