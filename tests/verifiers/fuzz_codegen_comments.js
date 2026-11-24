#!/usr/bin/env node
// Comment-placement fuzzer for the pretty printer.
//
// Fixtures rarely carry comments in unusual positions, so the round-trip gate
// says little about them. This check plants uniquely numbered comments at
// node boundaries of existing fixtures and requires, for every planted file
// that still parses:
//
//   1. the pretty print reparses to the same AST as the planted file, with
//      and without --preserve-parens (a comment must never change syntax);
//   2. every planted comment is present exactly once in the output;
//   3. printing the output again reproduces it byte for byte.
//
// Boundaries come from the pinned oxc-parser AST: every distinct node start
// and node end. Each round plants at a pseudo-random subset, alternating line
// and block comments, with a fixed seed so failures reproduce.
//
// Usage:
//   node tests/verifiers/fuzz_codegen_comments.js [options] <file|dir>...
//     --every <n>    keep every n-th input after sorting (default 1)
//     --rounds <n>   planted variants per input (default 3)
//     --seed <n>     base seed (default 1)
//     --keep <dir>   save the planted input and output of each failure
//     --replay       inputs are planted files saved by --keep; check them as is
'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

const ROOT = path.resolve(__dirname, '../..');
const KESSEL = path.join(ROOT, 'bin/kessel');
const { parseSync } = require(path.join(ROOT, 'bench/node_modules/oxc-parser'));

const options = { every: 1, rounds: 3, seed: 1, keep: '', replay: false, inputs: [] };
for (let i = 2; i < process.argv.length; i++) {
  const arg = process.argv[i];
  if (arg === '--every') options.every = parseInt(process.argv[++i], 10);
  else if (arg === '--rounds') options.rounds = parseInt(process.argv[++i], 10);
  else if (arg === '--seed') options.seed = parseInt(process.argv[++i], 10);
  else if (arg === '--keep') options.keep = path.resolve(process.argv[++i]);
  else if (arg === '--replay') options.replay = true;
  else options.inputs.push(path.resolve(arg));
}
if (options.inputs.length === 0) {
  console.error('usage: fuzz_codegen_comments.js [options] <file|dir>...');
  process.exit(2);
}

function walk(entry, out) {
  if (fs.statSync(entry).isFile()) { out.push(entry); return; }
  for (const name of fs.readdirSync(entry).sort()) {
    if (name === 'node_modules' || name === '.git' || name === 'recovery') continue;
    const full = path.join(entry, name);
    if (fs.statSync(full).isDirectory()) walk(full, out);
    else if (/\.(js|mjs|jsx|ts|tsx)$/.test(name) && !/\.d\.ts$/.test(name)) out.push(full);
  }
}

// Mirrors verify_codegen.js: fixture directories imply a dialect.
function dialectOf(file) {
  if (/\.tsx$/.test(file)) return 'tsx';
  if (/\.jsx$/.test(file)) return 'jsx';
  if (/\.ts$/.test(file)) return 'ts';
  if (file.includes('/spec/jsx/')) return 'jsx';
  if (file.includes('/spec/tsx/') || file.includes('/spec/ambiguity/')) return 'tsx';
  if (file.includes('/spec/typescript/')) return 'ts';
  if (/\/(interactions|es2025)\/[^/]*_jsx_/.test(file)) return 'jsx';
  if (/\/(interactions|es2025)\/[^/]*_ts_/.test(file)) return 'ts';
  if (file.includes('/babel/') && file.includes('/typescript/')) return 'ts';
  if (file.includes('/babel/') && file.includes('/jsx/')) return 'jsx';
  return 'js';
}

function run(args) {
  return execFileSync(KESSEL, args, {
    encoding: 'utf8', maxBuffer: 1 << 30, stdio: ['ignore', 'pipe', 'ignore'],
  });
}

const DROPPED = new Set(['start', 'end', 'range', 'loc', 'raw', 'comments']);
function ast(file, dialect, parens) {
  const args = ['parse', file, '--json', '--compact', '--lang=' + dialect];
  if (parens) args.push('--preserve-parens');
  const program = JSON.parse(run(args));
  if (program.errors && program.errors.length) return null;
  return JSON.stringify(program, (key, value) => (DROPPED.has(key) ? undefined : value));
}

function boundaries(file, source, dialect) {
  let parsed;
  try { parsed = parseSync('input.' + dialect, source); } catch { return null; }
  if (parsed.errors.length) return null;
  const offsets = new Set();
  const pending = [parsed.program];
  while (pending.length) {
    const value = pending.pop();
    if (value === null || typeof value !== 'object') continue;
    if (Array.isArray(value)) { for (const item of value) pending.push(item); continue; }
    if (typeof value.type === 'string' && typeof value.start === 'number') {
      offsets.add(value.start);
      offsets.add(value.end);
    }
    for (const key of Object.keys(value)) pending.push(value[key]);
  }
  // A comment may not split another comment.
  const inside = offset => parsed.comments.some(c => offset > c.start && offset < c.end);
  return [...offsets].filter(offset => !inside(offset)).sort((a, b) => a - b);
}

// Deterministic generator (mulberry32) so a seed names one planted file.
function generator(seed) {
  let state = seed >>> 0;
  return () => {
    state = (state + 0x6D2B79F5) >>> 0;
    let t = state;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function plant(source, offsets, random, density, lines) {
  const pieces = [];
  const ids = [];
  let cursor = 0;
  for (const offset of offsets) {
    if (random() >= density) continue;
    const id = `kc${ids.length}x`;
    ids.push(id);
    pieces.push(source.slice(cursor, offset));
    pieces.push(random() < lines ? ` // ${id}\n` : ` /* ${id} */ `);
    cursor = offset;
  }
  pieces.push(source.slice(cursor));
  return { text: pieces.join(''), ids };
}

function count(text, needle) {
  let total = 0;
  for (let at = text.indexOf(needle); at >= 0; at = text.indexOf(needle, at + needle.length)) total += 1;
  return total;
}

const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'kessel-comment-fuzz-'));
let variants = 0, unparseable = 0, failures = 0, planted = 0;

function fail(file, seed, reason, input, output, dialect) {
  failures += 1;
  console.error(`FAIL ${path.relative(fs.realpathSync(ROOT), fs.realpathSync(file))} seed=${seed}: ${reason}`);
  if (!options.keep) return;
  fs.mkdirSync(options.keep, { recursive: true });
  const stem = path.join(options.keep, `${failures}-${path.basename(file)}.seed${seed}`);
  fs.writeFileSync(`${stem}.in.${dialect}`, input);
  if (output !== null) fs.writeFileSync(`${stem}.out.${dialect}`, output);
}

function check(file, seed, dialect, input, ids) {
  const inputFile = path.join(scratch, 'input.' + dialect);
  const outputFile = path.join(scratch, 'output.' + dialect);
  fs.writeFileSync(inputFile, input);
  // Planting can produce source that only a lenient parser accepts.
  try {
    if (parseSync('input.' + dialect, input).errors.length) { unparseable += 1; return; }
  } catch { unparseable += 1; return; }
  for (const parens of [false, true]) {
    let original;
    try { original = ast(inputFile, dialect, parens); } catch { original = null; }
    if (original === null) { if (!parens) unparseable += 1; return; }
    const flags = ['--lang=' + dialect].concat(parens ? ['--preserve-parens'] : []);
    let output;
    try { output = run(['codegen', inputFile, ...flags]); } catch (error) {
      fail(file, seed, `printer exited abnormally (parens=${parens})`, input, null, dialect);
      return;
    }
    fs.writeFileSync(outputFile, output);
    let reparsed;
    try { reparsed = ast(outputFile, dialect, parens); } catch { reparsed = null; }
    if (reparsed !== original) {
      const why = reparsed === null ? 'output does not parse' : 'AST differs';
      fail(file, seed, `${why} (parens=${parens})`, input, output, dialect);
      return;
    }
    for (const id of ids) {
      const before = count(input, id), after = count(output, id);
      if (after !== before) {
        fail(file, seed, `comment ${id} appears ${after} times, expected ${before} (parens=${parens})`,
          input, output, dialect);
        return;
      }
    }
    let again;
    try { again = run(['codegen', outputFile, ...flags]); } catch { again = null; }
    if (again !== output) {
      fail(file, seed, `second print differs (parens=${parens})`, input, output, dialect);
      return;
    }
  }
  variants += 1;
  planted += ids.length;
}

const inputs = [];
for (const input of options.inputs) walk(input, inputs);
inputs.sort();
try {
  inputs.forEach((file, index) => {
    if (index % options.every !== 0) return;
    const dialect = dialectOf(file);
    const source = fs.readFileSync(file, 'utf8');
    if (options.replay) {
      if (/\.in\.[a-z]+$/.test(file)) check(file, 0, dialect, source, [...new Set(source.match(/kc\d+x/g) || [])]);
      return;
    }
    const offsets = boundaries(file, source, dialect);
    if (!offsets || offsets.length === 0) return;
    for (let round = 0; round < options.rounds; round++) {
      const seed = options.seed + index * 131 + round;
      const random = generator(seed);
      // The first round fills every boundary with block comments, which
      // seldom invalidate the source. Later rounds mix in line comments,
      // sparsely enough that most planted files still parse.
      const density = round === 0 ? 1 : (round % 2 ? 0.08 : 0.3);
      const { text, ids } = plant(source, offsets, random, density, round === 0 ? 0 : 0.4);
      if (ids.length) check(file, seed, dialect, text, ids);
    }
  });
} finally {
  fs.rmSync(scratch, { recursive: true, force: true });
}
console.log(`fuzz_codegen_comments: ${variants} planted files verified, ${planted} comments, ` +
  `${unparseable} planted files skipped (no longer valid source), ${failures} fail`);
process.exit(failures ? 1 : 0);
