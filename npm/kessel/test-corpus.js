#!/usr/bin/env node
/**
 * Corpus-wide npm package validation via CLI --binary.
 *
 * Parses every fixture through `kessel parse --binary` + JS binary reader
 * and reports crashes, decode errors, and missing node types.
 *
 * Usage:
 *   node npm/test-corpus.js                          # unit fixtures + real-world
 *   node npm/test-corpus.js --dir tests/fixtures     # specific directory
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');
const { decode } = require('./binary-reader');

const KESSEL = path.resolve(__dirname, '../../bin/kessel');
const args = process.argv.slice(2);
const specificDir = args.find((_, i, a) => a[i - 1] === '--dir');
const EXTENSIONS = new Set(['.js', '.jsx', '.ts', '.tsx', '.mjs', '.cjs', '.mts', '.cts']);

const DIRS = specificDir ? [specificDir] : ['tests/fixtures', 'bench/real_world'];

let total = 0, passed = 0, crashed = 0, decodeErrors = 0;
const failures = [];

function walkDir(dir) {
  let entries;
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); }
  catch { return; }
  for (const entry of entries) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) walkDir(full);
    else if (entry.isFile() && EXTENSIONS.has(path.extname(entry.name).toLowerCase())) testFile(full);
  }
}

function testFile(filePath) {
  total++;
  const source = fs.readFileSync(filePath, 'utf8');

  try {
    const buf = execFileSync(KESSEL, ['parse', filePath, '--binary'], {
      maxBuffer: 100 * 1024 * 1024,
      stdio: ['pipe', 'pipe', 'pipe'],
      timeout: 10000,
    });

    if (buf.length < 16) {
      decodeErrors++;
      failures.push({ file: filePath, error: `Binary output too small: ${buf.length} bytes` });
      return;
    }

    const { program } = decode(buf, source);

    if (!program || program.type !== 'Program') {
      decodeErrors++;
      failures.push({ file: filePath, error: `No Program node (got ${program?.type})` });
      return;
    }

    if (!Array.isArray(program.body)) {
      decodeErrors++;
      failures.push({ file: filePath, error: `program.body not array` });
      return;
    }

    passed++;
  } catch (e) {
    crashed++;
    failures.push({ file: filePath, error: e.message?.slice(0, 120) || String(e).slice(0, 120) });
  }

  if (total % 100 === 0) {
    process.stdout.write(`\r  ${total} tested, ${passed} ok, ${crashed + decodeErrors} failed`);
  }
}

console.log('kessel npm corpus validation (CLI --binary + JS reader)');
console.log('=======================================================\n');

const start = Date.now();
for (const dir of DIRS) {
  if (!fs.existsSync(dir)) { console.log(`  SKIP: ${dir}`); continue; }
  console.log(`  Scanning: ${dir}`);
  walkDir(dir);
}

process.stdout.write('\r' + ' '.repeat(80) + '\r');
const elapsed = ((Date.now() - start) / 1000).toFixed(1);

console.log(`\nResults (${elapsed}s):`);
console.log(`  Total:   ${total}`);
console.log(`  Passed:  ${passed}`);
console.log(`  Failed:  ${crashed + decodeErrors} (${crashed} crash, ${decodeErrors} decode)`);

if (failures.length > 0) {
  console.log(`\nFailures (first ${Math.min(failures.length, 30)}):`);
  for (const f of failures.slice(0, 30)) {
    console.log(`  ${f.file}`);
    console.log(`    ${f.error}`);
  }
}

console.log(failures.length === 0 ? '\n✓ All files passed.' : '\n✗ Failures detected.');
process.exit(failures.length > 0 ? 1 : 0);
