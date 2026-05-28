#!/usr/bin/env node
// Round-trip codegen conformance gate.
//
// For every fixture that parses cleanly:
//   parse(source)   -> ast_a
//   codegen(ast_a)  -> source'
//   parse(source')  -> ast_b
//   normalize(ast_a) === normalize(ast_b)
//
// "normalize" strips position fields (start/end/range/loc) and the
// Literal `raw` field — codegen re-emits literals in canonical form, so
// `raw` is allowed to drift. Everything else must match exactly.
//
// Exit 0 on full pass, 1 on any drift. Lists up to N failures with the
// first divergence path so triage is one grep away.

const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');

const ROOT = path.resolve(__dirname, '../..');
const KESSEL = path.join(ROOT, 'bin/kessel');
const FIXTURES_DIR = path.join(ROOT, 'tests/fixtures');
const VENDOR_DIR = path.join(ROOT, 'tests/vendor');

// Corpus selection. `--corpus spec` (default) runs the in-tree spec/
// fixtures only. The other values point at the vendored conformance
// corpora; `--corpus all` runs every supported corpus in sequence.
const CORPUS_ARG_IDX = process.argv.indexOf('--corpus');
const CORPUS = CORPUS_ARG_IDX > 0 ? process.argv[CORPUS_ARG_IDX + 1] : 'spec';
const CORPUS_LIMIT_IDX = process.argv.indexOf('--corpus-limit');
const CORPUS_LIMIT = CORPUS_LIMIT_IDX > 0
  ? parseInt(process.argv[CORPUS_LIMIT_IDX + 1], 10)
  : 0;
// `--minified` runs the round-trip with the codegen in minified mode
// (`kessel codegen --minified`). The reparsed AST must still match
// the original — a true regression-grade test of the minifier.
const MINIFIED = process.argv.includes('--minified');

const MAX_FAILURES_PRINTED = 25;

if (!fs.existsSync(KESSEL)) {
  console.error('verify_codegen: missing kessel binary at', KESSEL);
  process.exit(2);
}

// ---------------------------------------------------------------------------
// Fixture enumeration
// ---------------------------------------------------------------------------

// Directories whose entire contents are out of scope for round-trip
// codegen and must be excluded from enumeration. `recovery/` fixtures
// are deliberately malformed — they exist to exercise the parser's
// error-recovery paths, so by construction they cannot round-trip
// (parse → codegen → reparse) to the original AST. Counting them as
// `skip` made the verifier look like it had a 78-then-36 codegen
// backlog, when in reality the codegen pipeline has no work to do on
// those inputs at all.
const EXCLUDED_DIRS = new Set(['recovery']);

// Corpus roots — directory under which to walk, plus optional skip-path
// predicate that mirrors the conformance harness's `*_skip_path` rules.
const CORPUS_ROOTS = {
  spec: {
    root: FIXTURES_DIR,
    skip: null,
  },
  estree: {
    root: path.join(VENDOR_DIR, 'estree-conformance/tests'),
    // Skip support directories and JSON oracle files.
    skip: (p) => p.includes('/utils/') || /\.expected\.json$/.test(p),
  },
  babel: {
    root: path.join(VENDOR_DIR, 'babel/packages/babel-parser/test/fixtures'),
    // OXC-mirrored: only `input.*` is a fixture; everything else is
    // an option file, expected AST, or helper.
    skip: (p) => !/\/input\.(js|mjs|jsx|ts|tsx)$/.test(p),
  },
  test262: {
    root: path.join(VENDOR_DIR, 'test262/test'),
    // Mirrors tests/coverage/src/test262.odin: drop staging/, _FIXTURE
    // helper files, and intl402 (locale-dependent, not parser scope).
    skip: (p) =>
      p.includes('/staging/') ||
      p.includes('/intl402/') ||
      /_FIXTURE\.js$/.test(p),
  },
  ts: {
    root: path.join(VENDOR_DIR, 'typescript/tests/cases'),
    // TS fixtures contain many `// @filename` multi-file scripts that
    // need preprocessing; for the codegen gate, skip those for now
    // and pick up single-file fixtures only.
    skip: (p) => /\.d\.ts$/.test(p),
  },
};

function listFixtures() {
  const corpora = CORPUS === 'all'
    ? ['spec', 'estree', 'babel', 'test262', 'ts']
    : [CORPUS];
  for (const c of corpora) {
    if (!CORPUS_ROOTS[c]) {
      console.error(`verify_codegen: unknown --corpus "${c}" (expected spec|estree|babel|test262|ts|all)`);
      process.exit(2);
    }
  }
  const out = [];
  for (const c of corpora) {
    const { root, skip } = CORPUS_ROOTS[c];
    if (!fs.existsSync(root)) {
      console.error(`verify_codegen: corpus root missing for ${c}: ${root}`);
      process.exit(2);
    }
    walk(root, skip, out);
  }
  out.sort();
  if (CORPUS_LIMIT > 0 && out.length > CORPUS_LIMIT) {
    return out.slice(0, CORPUS_LIMIT);
  }
  return out;
}

function walk(dir, skip, out) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      if (EXCLUDED_DIRS.has(entry.name)) continue;
      if (entry.name === '.git') continue;
      if (entry.name === 'node_modules') continue;
      walk(full, skip, out);
    } else if (entry.isFile() && /\.(js|mjs|jsx|ts|tsx)$/.test(entry.name)) {
      if (skip && skip(full)) continue;
      out.push(full);
    }
  }
}

// ---------------------------------------------------------------------------
// Kessel drivers
// ---------------------------------------------------------------------------

// Dialect detection from file path. Mirrors verify_json_deep.js so kessel
// always knows which grammar to parse a fixture in. Without this, .js
// fixtures that contain TS or JSX syntax were rejected with K2040 /
// K2010 / K4053 / etc. and counted as skips even though they parse
// cleanly in the right --lang mode.
//   - JSX, TypeScript, and TSX-ambiguity families have their own dirs.
//   - `spec/interactions/` is mixed: filename markers carry the dialect.
function detectDialect(p) {
  // File extension is the highest-signal marker across all corpora.
  if (/\.tsx$/.test(p)) return 'tsx';
  if (/\.jsx$/.test(p)) return 'jsx';
  if (/\.ts$/.test(p))  return 'ts';
  if (/\.mjs$/.test(p)) return 'js';

  if (p.includes('/spec/jsx/'))        return 'jsx';
  if (p.includes('/spec/tsx/'))        return 'tsx';
  if (p.includes('/spec/typescript/')) return 'ts';
  if (p.includes('/spec/ambiguity/'))  return 'tsx';
  if (p.includes('/spec/interactions/')) {
    if (/_jsx_/.test(p)) return 'jsx';
    if (/_ts_/.test(p))  return 'ts';
  }
  // `es2025/0XX_jsx_*.js` and `es2025/0XX_ts_*.js` live next to plain JS
  // ES2025 fixtures; pick the right grammar from the filename marker.
  if (p.includes('/es2025/')) {
    if (/_jsx_/.test(p)) return 'jsx';
    if (/_ts_/.test(p))  return 'ts';
  }
  // Recovery TS/JSX bucket carries the dialect in its directory name.
  if (p.includes('/recovery/jsx_ts/')) {
    if (/_jsx_/.test(p) || /jsx/.test(path.basename(p))) return 'jsx';
    if (/_ts_/.test(p)  || /\bts\b/.test(path.basename(p))) return 'ts';
    return 'tsx';
  }
  // Vendor-corpus markers.
  //   * babel/.../typescript/   -> ts (input.ts present), jsx -> jsx, etc.
  //   * babel/.../jsx/          -> jsx
  //   * babel/.../flow/         -> js  (Flow not supported — will skip on parse error)
  if (p.includes('/babel/') && p.includes('/typescript/')) return 'ts';
  if (p.includes('/babel/') && p.includes('/jsx/'))        return 'jsx';
  return 'js';
}

function dialectExt(dialect) {
  switch (dialect) {
    case 'jsx': return '.jsx';
    case 'ts':  return '.ts';
    case 'tsx': return '.tsx';
    default:    return '.js';
  }
}

function parseToAst(filePath, dialect) {
  // --json mode always exits 0; errors are inside the JSON. Pass
  // --preserve-parens so semantic-bearing parens (e.g. `(class Foo {})`
  // in default-export position, `(await x) ** y` for the **-precedence
  // exception) survive the round-trip. The codegen call below uses the
  // same flag so emit and re-parse stay symmetric.
  const args = ['parse', filePath, '--json', '--preserve-parens'];
  if (dialect && dialect !== 'js') args.push('--lang=' + dialect);
  const out = execFileSync(KESSEL, args, {
    maxBuffer: 256 * 1024 * 1024,
    stdio: ['ignore', 'pipe', 'ignore'],
  });
  return JSON.parse(out.toString('utf8'));
}

function codegen(filePath, dialect) {
  const args = ['codegen', filePath, '--preserve-parens'];
  if (MINIFIED) args.push('--minified');
  if (dialect && dialect !== 'js') args.push('--lang=' + dialect);
  return execFileSync(KESSEL, args, {
    maxBuffer: 256 * 1024 * 1024,
    stdio: ['ignore', 'pipe', 'ignore'],
  }).toString('utf8');
}

// ---------------------------------------------------------------------------
// AST normalization + structural diff
// ---------------------------------------------------------------------------

// Position fields stripped from every node. `raw` on literals is stripped
// because codegen may canonicalize numeric / string forms (e.g. `0x10` vs
// `16`) and we only care that the parsed semantic value matches.
const STRIP_KEYS = new Set(['start', 'end', 'range', 'loc', 'raw']);

// Stripped only at the Program root:
//   - `errors` — re-parse must succeed cleanly, checked above the diff.
//   - `comments` — codegen does not emit comments yet (tracked as a
//     separate work-item). Comparing them would drown out real bugs.
const STRIP_TOP_LEVEL = new Set(['errors', 'comments']);

function normalize(node, isRoot = false) {
  if (node === null || node === undefined) return node;
  if (Array.isArray(node)) return node.map(c => normalize(c, false));
  if (typeof node !== 'object') return node;
  const out = {};
  for (const k of Object.keys(node)) {
    if (STRIP_KEYS.has(k)) continue;
    if (isRoot && STRIP_TOP_LEVEL.has(k)) continue;
    out[k] = normalize(node[k], false);
  }
  return out;
}

// Walk two normalized trees and return the first divergence as a string,
// or null on full equality. The string includes the JSON-path so triage
// is fast: e.g. `body[0].declarations[0].init.value`.
function firstDiff(a, b, p = '$') {
  if (a === b) return null;
  if (typeof a !== typeof b) {
    return `${p}: type ${typeof a} vs ${typeof b}`;
  }
  if (a === null || b === null) {
    return `${p}: ${JSON.stringify(a)} vs ${JSON.stringify(b)}`;
  }
  if (Array.isArray(a) || Array.isArray(b)) {
    if (!Array.isArray(a) || !Array.isArray(b)) {
      return `${p}: array vs non-array`;
    }
    if (a.length !== b.length) {
      return `${p}: length ${a.length} vs ${b.length}`;
    }
    for (let i = 0; i < a.length; i++) {
      const d = firstDiff(a[i], b[i], `${p}[${i}]`);
      if (d) return d;
    }
    return null;
  }
  if (typeof a === 'object') {
    const ka = Object.keys(a).sort();
    const kb = Object.keys(b).sort();
    if (ka.length !== kb.length || ka.some((k, i) => k !== kb[i])) {
      const only_a = ka.filter(k => !(k in b));
      const only_b = kb.filter(k => !(k in a));
      return `${p}: key drift {only_a:[${only_a}], only_b:[${only_b}]}`;
    }
    for (const k of ka) {
      const d = firstDiff(a[k], b[k], `${p}.${k}`);
      if (d) return d;
    }
    return null;
  }
  return `${p}: ${JSON.stringify(a)} vs ${JSON.stringify(b)}`;
}

// ---------------------------------------------------------------------------
// Round-trip a single fixture
// ---------------------------------------------------------------------------

function roundtrip(fixturePath, tmpRoot) {
  const dialect = detectDialect(fixturePath);
  // Step 1: parse original.
  let astA;
  try {
    astA = parseToAst(fixturePath, dialect);
  } catch (e) {
    return { kind: 'skip', reason: 'parse_invoke_failed: ' + (e.message || e) };
  }
  if (astA.errors && astA.errors.length > 0) {
    return { kind: 'skip', reason: 'parse_errors_in_source' };
  }

  // Step 2: codegen. Refuses to emit if there were parse errors, but we
  // already filtered those above. A non-zero exit here is a real failure.
  let src;
  try {
    src = codegen(fixturePath, dialect);
  } catch (e) {
    return { kind: 'fail', stage: 'codegen', detail: (e.stderr || '').toString().trim() || (e.message || String(e)) };
  }

  // Step 3: write to a temp file with the dialect-appropriate extension
  // and re-parse. The extension drives kessel's path-based lang detection
  // (.ts -> TS, .tsx -> TSX, etc.) as a defense in depth alongside the
  // explicit --lang flag we still pass.
  const ext = dialectExt(dialect);
  const base = path.basename(fixturePath, path.extname(fixturePath));
  const tmp = path.join(tmpRoot, `${base}.regen${ext}`);
  fs.writeFileSync(tmp, src);
  let astB;
  try {
    astB = parseToAst(tmp, dialect);
  } catch (e) {
    return { kind: 'fail', stage: 'reparse_invoke', detail: (e.message || String(e)) };
  }
  if (astB.errors && astB.errors.length > 0) {
    return {
      kind: 'fail',
      stage: 'reparse_errors',
      detail: astB.errors.slice(0, 3).map(e => `${e.code || '?'}: ${e.message}`).join(' | '),
      regen: src,
    };
  }

  // Step 4: structural diff.
  const a = normalize(astA, true);
  const b = normalize(astB, true);
  const diff = firstDiff(a, b);
  if (diff) {
    return { kind: 'fail', stage: 'ast_diff', detail: diff };
  }
  return { kind: 'pass' };
}

// ---------------------------------------------------------------------------
// Known-failure baseline
// ---------------------------------------------------------------------------

// Path is RELATIVE to tests/fixtures/. Mirrors the ambiguity baseline so
// the gate stays green on documented codegen gaps (mostly TS-erasure)
// while still catching real regressions and surfacing improvements.
const KNOWN_FAILURES_PATH = path.join(
  ROOT, 'tests/baselines/codegen_known_failures.txt',
);
function loadKnownFailures() {
  if (!fs.existsSync(KNOWN_FAILURES_PATH)) return new Set();
  const out = new Set();
  for (const raw of fs.readFileSync(KNOWN_FAILURES_PATH, 'utf8').split('\n')) {
    const trimmed = raw.replace(/#.*$/, '').trim();
    if (trimmed) out.add(trimmed);
  }
  return out;
}
const KNOWN_FAILURES = loadKnownFailures();

// Fixtures whose source intentionally contains parse errors (BOM-before-
// hashbang regression anchor, tsx-mode ambiguity recovery fixtures, etc.).
// Codegen refuses to emit when the parser produced errors, so these can
// never round-trip; the gate treats them as expected `intentional-skip`
// instead of either masking the count or flagging a regression.
const PARSE_ERROR_FIXTURES_PATH = path.join(
  ROOT, 'tests/baselines/codegen_parse_error_fixtures.txt',
);
function loadParseErrorFixtures() {
  if (!fs.existsSync(PARSE_ERROR_FIXTURES_PATH)) return new Set();
  const out = new Set();
  for (const raw of fs.readFileSync(PARSE_ERROR_FIXTURES_PATH, 'utf8').split('\n')) {
    const trimmed = raw.replace(/#.*$/, '').trim();
    if (trimmed) out.add(trimmed);
  }
  return out;
}
const PARSE_ERROR_FIXTURES = loadParseErrorFixtures();

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

const tmpRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'kessel-codegen-'));
process.on('exit', () => {
  try { fs.rmSync(tmpRoot, { recursive: true, force: true }); } catch {}
});

const fixtures = listFixtures();
let pass = 0, skip = 0, intentionalSkip = 0;
const failures = [];
const knownFailures = [];
const unexpectedPasses = [];
const unexpectedlyClean = [];

const t0 = Date.now();
for (const abs of fixtures) {
  const rel = path.relative(ROOT, abs);
  const inSpec = abs.startsWith(FIXTURES_DIR + path.sep);
  const relFromFixtures = inSpec ? path.relative(FIXTURES_DIR, abs) : rel;
  const isKnown = inSpec && KNOWN_FAILURES.has(relFromFixtures);
  const isParseError = inSpec && PARSE_ERROR_FIXTURES.has(relFromFixtures);
  const r = roundtrip(abs, tmpRoot);
  if (r.kind === 'pass') {
    pass++;
    if (isKnown) unexpectedPasses.push(relFromFixtures);
    if (isParseError) unexpectedlyClean.push(relFromFixtures);
  } else if (r.kind === 'skip') {
    if (isParseError && r.reason === 'parse_errors_in_source') {
      intentionalSkip++;
    } else {
      skip++;
      if (process.env.SHOW_SKIPS) console.log('SKIP', relFromFixtures, '--', r.reason);
    }
  } else if (isKnown) {
    knownFailures.push({ rel, ...r });
  } else {
    failures.push({ rel, ...r });
  }
}
const elapsed = ((Date.now() - t0) / 1000).toFixed(1);

console.log(
  `verify_codegen: ${fixtures.length} fixtures, ${pass} pass, ${skip} skip, ` +
  `${intentionalSkip} intentional-skip, ` +
  `${failures.length} fail, ${knownFailures.length} known-fail (${elapsed}s)`,
);

if (unexpectedlyClean.length > 0) {
  console.log('');
  console.log('  Improvements \u2014 these are listed in codegen_parse_error_fixtures.txt');
  console.log('  but now PARSE CLEANLY. Remove them from the baseline:');
  for (const p of unexpectedlyClean) console.log(`    - ${p}`);
}

if (unexpectedPasses.length > 0) {
  console.log('');
  console.log('  Improvements \u2014 these are listed in codegen_known_failures.txt');
  console.log('  but now ROUND-TRIP CLEANLY. Remove them from the baseline:');
  for (const p of unexpectedPasses) console.log(`    - ${p}`);
}

if (failures.length > 0) {
  // Group by stage for a quick overview.
  const byStage = new Map();
  for (const f of failures) byStage.set(f.stage, (byStage.get(f.stage) || 0) + 1);
  console.log('  by stage:', [...byStage.entries()].map(([s, n]) => `${s}=${n}`).join(' '));

  const show = failures.slice(0, MAX_FAILURES_PRINTED);
  for (const f of show) {
    console.log(`  FAIL [${f.stage}] ${f.rel}`);
    console.log(`         ${f.detail}`);
  }
  if (failures.length > MAX_FAILURES_PRINTED) {
    console.log(`  ... and ${failures.length - MAX_FAILURES_PRINTED} more`);
  }
  process.exit(1);
}

process.exit(0);
