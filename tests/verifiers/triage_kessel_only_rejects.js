#!/usr/bin/env node
// Triage helper for S26 W6 phase 3: walk every kessel-only-rejects file,
// run kessel, capture the FIRST parse-error message, cluster by that message.
//
// Sub-directory clustering shows where the bugs live; error-message clustering
// shows what they are. A 200-file cluster all reporting "Expected from, got ="
// is one bug class — TSImportEqualsDeclaration. A 50-file cluster reporting
// "Unexpected token '!'" might be TS non-null on an expression edge case.
//
// Usage: node tests/verifiers/triage_kessel_only_rejects.js [--max-per-cluster N]

'use strict';
const fs = require('fs');
const path = require('path');
const os = require('os');
const { spawn } = require('child_process');

const ROOT = path.resolve(__dirname, '../..');
const KESSEL = path.join(ROOT, 'bin/kessel');
const SMOKE_JSON = path.join(ROOT, 'tmp/_w6_full_smoke.json');

const argv = process.argv.slice(2);
const maxPerCluster = (() => {
  const i = argv.indexOf('--max-per-cluster');
  return i >= 0 ? parseInt(argv[i+1], 10) : 5;
})();

if (!fs.existsSync(SMOKE_JSON)) {
  console.error(`No ${SMOKE_JSON}. Run: node tests/verifiers/verify_oxc_corpus.js --json-out tmp/_w6_full_smoke.json`);
  process.exit(2);
}

const j = JSON.parse(fs.readFileSync(SMOKE_JSON, 'utf8'));
let rejects = j.failures.filter(f => f.verdict === 'kessel-only-rejects');
console.error(`Found ${rejects.length} kessel-only-rejects in JSON (gate baseline: ${j.summary.verdicts['kessel-only-rejects']}).`);

// Note: the smoke JSON caps each verdict at 500. To re-triage the full 2,622,
// re-run verify_oxc_corpus.js with --json-out and a higher cap, or call this
// script multiple times. For now, the 500-sample cap gives us representative
// clustering — the top clusters are what we want anyway.

function suiteToVendorPath(suite, file) {
  if (suite === 'typescript') return path.join(ROOT, 'vendor/typescript/tests/cases', file);
  if (suite === 'babel')      return path.join(ROOT, 'vendor/babel/packages/babel-parser/test/fixtures', file);
  if (suite === 'estree')     return path.join(ROOT, 'vendor/estree-conformance/tests/acorn-jsx/pass', file);
  return null;
}

function langForRel(suite, file) {
  if (suite === 'estree') return 'jsx';
  const ext = path.extname(file);
  if (ext === '.tsx') return 'tsx';
  if (ext === '.ts')  return 'ts';
  if (ext === '.jsx') return 'jsx';
  return '';
}

function runKessel(abs, lang) {
  return new Promise((resolve) => {
    const cliArgs = ['parse', abs, '--compact'];
    if (lang) cliArgs.push(`--lang=${lang}`);
    const proc = spawn(KESSEL, cliArgs, { stdio:['ignore','pipe','pipe'] });
    const chunks = [];
    const tid = setTimeout(() => { try { proc.kill('SIGKILL'); } catch {} }, 5000);
    proc.stdout.on('data', (c) => { chunks.push(c); });
    proc.stderr.on('data', () => {});
    proc.on('close', () => {
      clearTimeout(tid);
      // The error messages live in the JSON AST `errors` array on stdout, not
      // in stderr (--compact doesn't pretty-print them). Parse the first line
      // (the AST is single-line in --compact mode) and read errors[0].message.
      const buf = Buffer.concat(chunks);
      const nl = buf.indexOf('\n');
      const json = nl >= 0 ? buf.slice(0, nl).toString('utf8') : buf.toString('utf8');
      try {
        const tree = JSON.parse(json);
        if (tree.errors && tree.errors.length > 0 && tree.errors[0].message) {
          resolve(tree.errors[0].message);
          return;
        }
      } catch {}
      resolve(null);
    });
    proc.on('error', () => { clearTimeout(tid); resolve(null); });
  });
}

(async () => {
  const concurrency = Math.min(os.cpus().length, 16);
  const t0 = Date.now();
  const clusters = new Map();  // err msg → array of files
  let next = 0;
  let inflight = 0;
  let done = 0;

  await new Promise((resolve) => {
    function trySpawn() {
      while (inflight < concurrency && next < rejects.length) {
        const f = rejects[next++];
        inflight++;
        const abs = suiteToVendorPath(f.suite, f.file);
        const lang = langForRel(f.suite, f.file);
        runKessel(abs, lang).then((msg) => {
          inflight--; done++;
          const key = msg || '<no-error-captured>';
          if (!clusters.has(key)) clusters.set(key, []);
          clusters.get(key).push(`${f.suite}/${f.file}`);
          if (done === rejects.length) resolve();
          else trySpawn();
        });
      }
    }
    trySpawn();
  });

  const elapsed = ((Date.now() - t0) / 1000).toFixed(1);
  console.error(`Done in ${elapsed}s.\n`);

  // Sort clusters by size, biggest first.
  const sorted = [...clusters.entries()].sort((a,b) => b[1].length - a[1].length);

  console.log(`# kessel-only-rejects clustered by first error message (${rejects.length} files, ${sorted.length} distinct messages)\n`);
  let cum = 0;
  for (const [msg, files] of sorted) {
    cum += files.length;
    const pct = ((cum / rejects.length) * 100).toFixed(1);
    console.log(`## [${files.length} files, ${pct}% cum] ${msg}`);
    for (const f of files.slice(0, maxPerCluster)) {
      console.log(`  - ${f}`);
    }
    if (files.length > maxPerCluster) {
      console.log(`  - ...and ${files.length - maxPerCluster} more`);
    }
    console.log('');
  }
})().catch((e) => { console.error(e); process.exit(2); });
