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

const MAX_FAILURES_PRINTED = 25;

if (!fs.existsSync(KESSEL)) {
  console.error('verify_codegen: missing kessel binary at', KESSEL);
  process.exit(2);
}

// ---------------------------------------------------------------------------
// Fixture enumeration
// ---------------------------------------------------------------------------

function listFixtures() {
  const out = [];
  function walk(dir) {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) walk(full);
      else if (entry.isFile() && /\.(js|mjs|jsx|ts|tsx)$/.test(entry.name)) out.push(full);
    }
  }
  walk(FIXTURES_DIR);
  return out.sort();
}

// ---------------------------------------------------------------------------
// Kessel drivers
// ---------------------------------------------------------------------------

function parseToAst(filePath) {
  // --json mode always exits 0; errors are inside the JSON.
  const out = execFileSync(KESSEL, ['parse', filePath, '--json'], {
    maxBuffer: 256 * 1024 * 1024,
    stdio: ['ignore', 'pipe', 'ignore'],
  });
  return JSON.parse(out.toString('utf8'));
}

function codegen(filePath) {
  return execFileSync(KESSEL, ['codegen', filePath], {
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
  // Step 1: parse original.
  let astA;
  try {
    astA = parseToAst(fixturePath);
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
    src = codegen(fixturePath);
  } catch (e) {
    return { kind: 'fail', stage: 'codegen', detail: (e.stderr || '').toString().trim() || (e.message || String(e)) };
  }

  // Step 3: write to a temp file with the same extension and re-parse.
  // The extension drives lang detection (.ts -> TS, .tsx -> TSX, etc.).
  const ext = path.extname(fixturePath);
  const base = path.basename(fixturePath, ext);
  const tmp = path.join(tmpRoot, `${base}.regen${ext}`);
  fs.writeFileSync(tmp, src);
  let astB;
  try {
    astB = parseToAst(tmp);
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
// Main
// ---------------------------------------------------------------------------

const tmpRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'kessel-codegen-'));
process.on('exit', () => {
  try { fs.rmSync(tmpRoot, { recursive: true, force: true }); } catch {}
});

const fixtures = listFixtures();
let pass = 0, skip = 0;
const failures = [];

const t0 = Date.now();
for (const abs of fixtures) {
  const rel = path.relative(ROOT, abs);
  const r = roundtrip(abs, tmpRoot);
  if (r.kind === 'pass') pass++;
  else if (r.kind === 'skip') skip++;
  else failures.push({ rel, ...r });
}
const elapsed = ((Date.now() - t0) / 1000).toFixed(1);

console.log(`verify_codegen: ${fixtures.length} fixtures, ${pass} pass, ${skip} skip, ${failures.length} fail (${elapsed}s)`);

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
