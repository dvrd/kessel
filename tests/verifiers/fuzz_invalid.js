#!/usr/bin/env node
// Mutation fuzzer for INVALID input.
//
// Contract: the parser must never crash. For any byte sequence we throw at
// it \u2014 malformed UTF-8, truncated escapes, embedded NULs, mid-token EOFs,
// bit-flipped real files, 1-MB single identifiers, whatever \u2014 the binary
// must exit with a status code in {0, 1} within a deadline. Any signal-
// terminated exit (>=128 on POSIX: SIGSEGV=139, SIGABRT=134, SIGTRAP=133,
// SIGBUS=138, ...), or any timeout, is a CRASH and fails the gate.
//
// This is distinct from fuzz_diff.js, which fuzzes VALID input and diffs
// ASTs vs OXC. Invalid-input fuzzing finds a different bug class: lexer
// assertion failures, integer underflow on truncated escapes, infinite
// loops on malformed tokens. The three pre-existing SIGTRAPs in
// tests/baselines/unit_known_failures.txt are exactly this class.
//
// Mutation strategies (each case picks one, weighted):
//   - bit_flip:    flip N random bits in a random real-world file
//   - byte_drop:   delete N random byte runs
//   - byte_insert: insert N random bytes at random offsets
//   - truncate:    take random prefix only (mid-token EOF)
//   - ascii_noise: prepend/append ASCII garbage
//   - nul_inject:  insert embedded \\0 bytes
//   - utf8_broken: inject illegal UTF-8 sequences (e.g. 0xC0 0x80, lone
//                  continuation byte, 5-byte sequences)
//   - escape_truncate: find every `\\u...` and snip it mid-sequence
//   - pile_of_nesting: brand-new program of N-deep nested parens/braces
//
// Deterministic given a seed. Crashes are copied to tmp/fuzz_invalid_crashes/
// keyed by content hash.
//
// Usage:
//   node tests/verifiers/fuzz_invalid.js                        # default
//   node tests/verifiers/fuzz_invalid.js --count 500 --seed 42
//   node tests/verifiers/fuzz_invalid.js --baseline             # gated (chain)
//   node tests/verifiers/fuzz_invalid.js --update               # recapture
//   node tests/verifiers/fuzz_invalid.js --strict               # 0 crashes
//
// Baseline mode mirrors fuzz_diff.js: per-hash locked set, new hashes regress.
// We expect the baseline to start empty \u2014 any crash is a bug worth fixing.
// The baseline exists so a new crash class gets surfaced without also
// re-blocking a regression we've already triaged.

'use strict';
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { spawnSync } = require('child_process');

const ROOT = path.resolve(__dirname, '../..');
const KESSEL = path.join(ROOT, 'bin/kessel');
const CORPUS_DIR = path.join(ROOT, 'bench/real_world');
const TMP_DIR = path.join(ROOT, 'tmp/fuzz_invalid');
const CRASH_DIR = path.join(ROOT, 'tmp/fuzz_invalid_crashes');
const BASELINE_PATH = path.join(ROOT, 'tests/baselines/fuzz_invalid_baseline.json');

fs.mkdirSync(TMP_DIR, { recursive: true });
fs.mkdirSync(CRASH_DIR, { recursive: true });

const args = process.argv.slice(2);
function arg(name, def) {
  const i = args.indexOf(name);
  return i >= 0 ? args[i + 1] : def;
}
const COUNT    = parseInt(arg('--count', '300'), 10);
const SEED     = parseInt(arg('--seed', String(Date.now() & 0xffffffff)), 10);
const DEADLINE = parseInt(arg('--deadline-ms', '5000'), 10);
const VERBOSE  = args.includes('--verbose');
const BASELINE = args.includes('--baseline');
const UPDATE   = args.includes('--update');
const STRICT   = args.includes('--strict');

if ([BASELINE, UPDATE, STRICT].filter(Boolean).length > 1) {
  console.error('fuzz_invalid: pass at most one of --baseline, --update, --strict');
  process.exit(2);
}

if (!fs.existsSync(KESSEL)) {
  console.error('fuzz_invalid: missing ' + KESSEL + ' \u2014 run `task build` first');
  process.exit(2);
}

// Mulberry32 PRNG \u2014 same as fuzz_diff.js, deterministic given a seed.
function makePrng(seed) {
  let s = (seed >>> 0) || 1;
  return function () {
    s |= 0; s = (s + 0x6D2B79F5) | 0;
    let t = Math.imul(s ^ (s >>> 15), 1 | s);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

// -----------------------------------------------------------------------------
// Corpus seed files. We mutate bytes from these; they're statistically
// representative of what kessel parses in production.
// -----------------------------------------------------------------------------
function listCorpus() {
  const out = [];
  function walk(dir) {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) walk(full);
      else if (entry.isFile() && /\.(js|mjs)$/.test(entry.name)) out.push(full);
    }
  }
  walk(CORPUS_DIR);
  return out.sort();
}

// -----------------------------------------------------------------------------
// Mutation strategies. Each takes (rng, src: Buffer) and returns a Buffer.
// Kept small and inlineable so a reviewer can eyeball what each one produces.
// -----------------------------------------------------------------------------
function randInt(rng, n) { return Math.floor(rng() * n); }
function randByte(rng)   { return randInt(rng, 256); }

function mutBitFlip(rng, src) {
  if (src.length === 0) return src;
  const out = Buffer.from(src);
  const flips = 1 + randInt(rng, 16);
  for (let i = 0; i < flips; i++) {
    const off = randInt(rng, out.length);
    const bit = 1 << randInt(rng, 8);
    out[off] ^= bit;
  }
  return out;
}

function mutByteDrop(rng, src) {
  if (src.length < 2) return src;
  const start = randInt(rng, src.length);
  const len = 1 + randInt(rng, Math.min(64, src.length - start));
  return Buffer.concat([src.slice(0, start), src.slice(start + len)]);
}

function mutByteInsert(rng, src) {
  const off = randInt(rng, src.length + 1);
  const n = 1 + randInt(rng, 32);
  const garbage = Buffer.alloc(n);
  for (let i = 0; i < n; i++) garbage[i] = randByte(rng);
  return Buffer.concat([src.slice(0, off), garbage, src.slice(off)]);
}

function mutTruncate(rng, src) {
  if (src.length < 2) return src;
  // Favour short truncations \u2014 mid-first-token EOF is the juiciest.
  const keep = 1 + randInt(rng, Math.min(2048, src.length - 1));
  return src.slice(0, keep);
}

function mutAsciiNoise(rng, src) {
  const pool = '!@#$%^&*()[]{}<>?,./\\\\|`~=+-_\'" \\t\\n\\r';
  const n = 8 + randInt(rng, 512);
  const g = Buffer.alloc(n);
  for (let i = 0; i < n; i++) g[i] = pool.charCodeAt(randInt(rng, pool.length));
  return rng() < 0.5 ? Buffer.concat([g, src]) : Buffer.concat([src, g]);
}

function mutNulInject(rng, src) {
  const out = Buffer.from(src);
  const n = 1 + randInt(rng, 8);
  for (let i = 0; i < n; i++) out[randInt(rng, out.length)] = 0;
  return out;
}

// Inject illegal UTF-8 patterns. A real lexer has to fail cleanly on these;
// a lexer that byte-decodes without validation can walk off the end or read
// stale bytes. Patterns chosen from RFC 3629 \u00a74 and real CVE history.
const BROKEN_UTF8_PATTERNS = [
  Buffer.from([0xC0, 0x80]),             // overlong NUL encoding
  Buffer.from([0xC1, 0xBF]),             // overlong 2-byte
  Buffer.from([0xE0, 0x80, 0x80]),       // overlong 3-byte
  Buffer.from([0xF0, 0x80, 0x80, 0x80]), // overlong 4-byte
  Buffer.from([0xED, 0xA0, 0x80]),       // UTF-16 surrogate half U+D800
  Buffer.from([0xED, 0xBF, 0xBF]),       // surrogate half U+DFFF
  Buffer.from([0xF4, 0x90, 0x80, 0x80]), // codepoint above U+10FFFF
  Buffer.from([0xFE]),                   // 5-byte lead (illegal)
  Buffer.from([0xFF]),                   // 6-byte lead (illegal)
  Buffer.from([0x80]),                   // lone continuation byte
  Buffer.from([0xC2]),                   // truncated 2-byte (no cont)
  Buffer.from([0xE0, 0xA0]),             // truncated 3-byte
];
function mutUtf8Broken(rng, src) {
  const pattern = BROKEN_UTF8_PATTERNS[randInt(rng, BROKEN_UTF8_PATTERNS.length)];
  const off = randInt(rng, src.length + 1);
  return Buffer.concat([src.slice(0, off), pattern, src.slice(off)]);
}

// Find a `\\uXXXX` or `\\u{...}` and snip off the end \u2014 the lexer has to
// handle mid-escape EOF gracefully (historic crash class).
function mutEscapeTruncate(rng, src) {
  const s = src.toString('utf8');
  const positions = [];
  for (let i = 0; i < s.length - 1; i++) {
    if (s[i] === '\\\\' && (s[i+1] === 'u' || s[i+1] === 'x')) positions.push(i);
  }
  if (positions.length === 0) return mutTruncate(rng, src);
  const pos = positions[randInt(rng, positions.length)];
  // Keep up to pos+2, dropping the hex tail. Appends one random hex byte
  // and stops \u2014 leaving the escape truncated.
  const tail = '0123456789abcdef'[randInt(rng, 16)];
  return Buffer.concat([src.slice(0, pos + 2), Buffer.from(tail, 'ascii')]);
}

function mutPileOfNesting(rng, _src) {
  // Ignore seed; generate O(N) nested structures. If the parser recurses
  // without a depth cap it will SIGSEGV on stack overflow here.
  const depth = 500 + randInt(rng, 3000);
  const chars = '([{(([{'; // intentionally unbalanced across openers
  let out = '';
  for (let i = 0; i < depth; i++) out += chars[i % chars.length];
  return Buffer.from(out, 'ascii');
}

const STRATEGIES = [
  { name: 'bit_flip',         fn: mutBitFlip,        weight: 12 },
  { name: 'byte_drop',        fn: mutByteDrop,       weight:  8 },
  { name: 'byte_insert',      fn: mutByteInsert,     weight:  8 },
  { name: 'truncate',         fn: mutTruncate,       weight: 10 },
  { name: 'ascii_noise',      fn: mutAsciiNoise,     weight:  5 },
  { name: 'nul_inject',       fn: mutNulInject,      weight:  6 },
  { name: 'utf8_broken',      fn: mutUtf8Broken,     weight: 10 },
  { name: 'escape_truncate',  fn: mutEscapeTruncate, weight:  6 },
  { name: 'pile_of_nesting',  fn: mutPileOfNesting,  weight:  3 },
];
const TOTAL_WEIGHT = STRATEGIES.reduce((a, s) => a + s.weight, 0);

function pickStrategy(rng) {
  let r = rng() * TOTAL_WEIGHT;
  for (const s of STRATEGIES) {
    r -= s.weight;
    if (r <= 0) return s;
  }
  return STRATEGIES[0];
}

// -----------------------------------------------------------------------------
// Drive.
// -----------------------------------------------------------------------------
console.log('fuzz_invalid: count=' + COUNT + ' seed=' + SEED + ' deadline=' + DEADLINE + 'ms' +
            (BASELINE ? ' mode=baseline' : UPDATE ? ' mode=update' :
             STRICT ? ' mode=strict' : ''));

const corpus = listCorpus();
if (corpus.length === 0) {
  console.error('fuzz_invalid: empty corpus at ' + CORPUS_DIR);
  process.exit(2);
}
const rng = makePrng(SEED);

// hash -> { exit, signal, strategy, size }
// Only crashes (signal-terminated OR exit >= 128 OR timeout) are recorded;
// exit codes 0 and 1 are the expected range ("parsed ok" or "parse error").
const crashes = Object.create(null);
const byStrategy = Object.create(null);
let ok = 0;
let total = 0;

for (let i = 0; i < COUNT; i++) {
  const src = fs.readFileSync(corpus[randInt(rng, corpus.length)]);
  const strat = pickStrategy(rng);
  let mutated;
  try {
    mutated = strat.fn(rng, src);
  } catch (e) {
    // Mutation itself shouldn't throw; if it does, log and skip.
    console.warn('  [' + i + '] mutator ' + strat.name + ' threw: ' + e.message);
    continue;
  }
  total++;
  byStrategy[strat.name] = (byStrategy[strat.name] || 0) + 1;

  const h = crypto.createHash('sha1').update(mutated).digest('hex').slice(0, 8);
  const inputPath = path.join(TMP_DIR, 'case_' + h + '.js');
  fs.writeFileSync(inputPath, mutated);

  // Run kessel. timeout is enforced by spawnSync(timeout); on hit it
  // returns status=null, signal='SIGTERM'. Any non-{0,1} exit is a crash.
  const r = spawnSync(KESSEL, ['parse', inputPath], {
    encoding: 'buffer',
    maxBuffer: 32 * 1024 * 1024,
    timeout: DEADLINE,
  });

  let crash = null;
  if (r.error && r.error.code === 'ETIMEDOUT') {
    crash = { reason: 'timeout', exit: null, signal: null };
  } else if (r.signal) {
    crash = { reason: 'signal', exit: null, signal: r.signal };
  } else if (typeof r.status === 'number' && (r.status < 0 || r.status > 1)) {
    // Exit codes 134 (SIGABRT), 133 (SIGTRAP), 139 (SIGSEGV), 137 (SIGKILL),
    // 138 (SIGBUS) all land here on macOS/Linux when a child is killed.
    // Anything outside {0, 1} is unexpected for a parser's main path.
    crash = { reason: 'exit', exit: r.status, signal: null };
  }

  if (crash) {
    // Copy to the crash dir (separate from TMP_DIR so `tmp/fuzz_invalid/`
    // can be auto-pruned without losing triage data).
    const cp = path.join(CRASH_DIR, 'case_' + h + '.js');
    fs.writeFileSync(cp, mutated);
    crashes[h] = {
      reason: crash.reason,
      exit: crash.exit,
      signal: crash.signal,
      strategy: strat.name,
      size: mutated.length,
    };
    if (VERBOSE || Object.keys(crashes).length <= 5) {
      console.log('  [' + i + '] CRASH (' + h + ') strat=' + strat.name +
                  ' reason=' + crash.reason +
                  (crash.signal ? ' signal=' + crash.signal : '') +
                  (crash.exit !== null ? ' exit=' + crash.exit : '') +
                  ' size=' + mutated.length + 'B \u2192 ' + cp);
    }
  } else {
    ok++;
  }
}

console.log('\\nfuzz_invalid: ' + ok + '/' + total + ' exited cleanly, ' +
            Object.keys(crashes).length + ' unique crashes');
console.log('seed=' + SEED + ' (reproduce with --seed ' + SEED + ')');

// Per-strategy crash rate \u2014 useful for triage.
const stratCrashes = Object.create(null);
for (const c of Object.values(crashes)) {
  stratCrashes[c.strategy] = (stratCrashes[c.strategy] || 0) + 1;
}
for (const name of Object.keys(byStrategy).sort()) {
  const runs = byStrategy[name];
  const crashed = stratCrashes[name] || 0;
  if (crashed > 0) {
    console.log('  ' + name.padEnd(18) + ': ' + crashed + '/' + runs + ' crashed');
  }
}

// -----------------------------------------------------------------------------
// Gate / baseline logic \u2014 same semantics as fuzz_diff.js.
// -----------------------------------------------------------------------------
if (UPDATE) {
  fs.writeFileSync(BASELINE_PATH, JSON.stringify({
    seed: SEED, count: COUNT, corpus_size: corpus.length,
    known_crashes: crashes,
  }, null, 2) + '\n');
  console.log('baseline updated: ' + Object.keys(crashes).length + ' known crash(es) in ' + BASELINE_PATH);
  process.exit(0);
}

if (BASELINE) {
  if (!fs.existsSync(BASELINE_PATH)) {
    // First run: treat a missing baseline as empty-baseline (\"all crashes
    // are regressions\"). Exit 1 with a hint; the human runs --update once
    // they've either triaged the crashes or verified the baseline should
    // indeed be non-empty.
    if (Object.keys(crashes).length > 0) {
      console.error('fuzz_invalid: ' + Object.keys(crashes).length +
                    ' crash(es) found with no baseline. Triage each, then run --update.');
      process.exit(1);
    }
    console.log('fuzz_invalid: no crashes, no baseline \u2014 creating empty baseline.');
    fs.writeFileSync(BASELINE_PATH, JSON.stringify({
      seed: SEED, count: COUNT, corpus_size: corpus.length, known_crashes: {},
    }, null, 2) + '\n');
    process.exit(0);
  }
  const baseline = JSON.parse(fs.readFileSync(BASELINE_PATH, 'utf8'));
  if (baseline.seed !== SEED || baseline.count !== COUNT) {
    console.error('fuzz_invalid: baseline seed/count mismatch. Baseline seed=' +
                  baseline.seed + ' count=' + baseline.count +
                  ', running with seed=' + SEED + ' count=' + COUNT);
    process.exit(2);
  }
  const known = baseline.known_crashes || {};
  const newCrashes = Object.keys(crashes).filter(h => !(h in known));
  const fixed = Object.keys(known).filter(h => !(h in crashes));

  if (fixed.length > 0) {
    console.log('\\nIMPROVEMENTS: ' + fixed.length + ' baselined crash(es) now clean:');
    for (const h of fixed) {
      const k = known[h];
      console.log('  ' + h + '  ' + k.strategy + ' ' + (k.signal || 'exit=' + k.exit));
    }
    console.log('  Run with --update to lock these in.');
  }
  if (newCrashes.length > 0) {
    console.log('\\nREGRESSIONS: ' + newCrashes.length + ' NEW crash(es) (not in baseline):');
    for (const h of newCrashes) {
      const k = crashes[h];
      console.log('  ' + h + '  ' + k.strategy + ' ' + (k.signal || 'exit=' + k.exit) + ' size=' + k.size + 'B');
    }
    process.exit(1);
  }
  console.log('OK: ' + Object.keys(crashes).length + '/' + Object.keys(known).length +
              ' baselined crash(es) still reproduce, 0 new.');
  process.exit(0);
}

if (STRICT) {
  process.exit(Object.keys(crashes).length > 0 ? 1 : 0);
}

// Default (exploratory) \u2014 any crash fails.
process.exit(Object.keys(crashes).length > 0 ? 1 : 0);
