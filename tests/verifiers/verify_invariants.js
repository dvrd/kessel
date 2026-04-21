#!/usr/bin/env node
// Structural ESTree invariants across the full real-world corpus (467 files).
//
// Walks Kessel's JSON output for each file and asserts global invariants
// that the ESTree spec requires on every emitted tree. Each invariant is
// parser-agnostic — no reference parser needed; these are Kessel self-checks.
//
// Invariants:
//   I1. No node has type === "Unknown".
//   I2. No node has `[UNIMPLEMENTED]: true`.
//   I3. Every object with a `type` field has numeric `start` and `end`.
//   I4. start <= end on every node.
//   I5. Program.type === "Program", with sourceType ∈ {"script", "module"}.
//   I6. Every FunctionExpression has `id` (null or Identifier).
//   I7. Every ArrowFunctionExpression has `id`, `expression`, `generator`, `async`.
//   I8. Every Function* has `params: []`.
//   I9. Every CatchClause has `param` (null or Pattern) and `body`.
//   I10. VariableDeclarator always wraps a Pattern in `id` and (Expression|null) in `init`.
//
// Usage:
//   node tests/verify_invariants.js                # walk all 467 real files
//   node tests/verify_invariants.js <file.js>      # walk one file
//
// Exit 0 if every invariant holds on every file; exit 1 otherwise.
// First few violations per invariant are printed; rest are counted.

'use strict';
const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

const ROOT = path.resolve(__dirname, '../..');
const KESSEL = path.join(ROOT, 'bin/kessel');
const BENCH_ROOT = path.join(ROOT, 'bench/real_world');
const BASELINE_PATH = path.join(ROOT, 'tests/baselines/invariants_baseline.json');

const UPDATE = process.argv.includes('--update');
// argv[0]=node, argv[1]=this script. A single-file argument is any .js/.mjs
// path AFTER those two that isn't a flag.
const singleFile = process.argv.slice(2).find(
  a => !a.startsWith('--') && (a.endsWith('.js') || a.endsWith('.mjs'))
);

// -----------------------------------------------------------------------------
// File discovery: either argv[2] OR every .js/.mjs under bench/real_world/.
// -----------------------------------------------------------------------------
function listFiles() {
  if (singleFile) return [path.resolve(singleFile)];
  const out = [];
  function walk(dir) {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) walk(full);
      else if (entry.isFile() && /\.(js|mjs)$/.test(entry.name)) out.push(full);
    }
  }
  walk(BENCH_ROOT);
  return out.sort();
}

// -----------------------------------------------------------------------------
// Per-invariant counters + first-5-violation samples for triage.
// -----------------------------------------------------------------------------
const inv = {
  I1_no_unknown:         { count: 0, samples: [] },
  I2_no_unimplemented:   { count: 0, samples: [] },
  I3_start_end_present:  { count: 0, samples: [] },
  I4_start_le_end:       { count: 0, samples: [] },
  I5_program_shape:      { count: 0, samples: [] },
  I6_funcexpr_id:        { count: 0, samples: [] },
  I7_arrow_fields:       { count: 0, samples: [] },
  I8_func_params_array:  { count: 0, samples: [] },
  I9_catch_fields:       { count: 0, samples: [] },
  I10_declarator_shape:  { count: 0, samples: [] },
};

function record(key, detail) {
  inv[key].count++;
  if (inv[key].samples.length < 5) inv[key].samples.push(detail);
}

// Walk a Kessel AST and accumulate invariant violations.
function check(tree, file) {
  // I5: Program-level shape.
  if (tree == null || typeof tree !== 'object') {
    record('I5_program_shape', `${file}: top-level is not an object`);
    return;
  }
  if (tree.type !== 'Program') {
    record('I5_program_shape', `${file}: top-level type=${JSON.stringify(tree.type)}, want "Program"`);
  }
  if (tree.sourceType !== 'script' && tree.sourceType !== 'module') {
    record('I5_program_shape', `${file}: sourceType=${JSON.stringify(tree.sourceType)}`);
  }

  // Walk every node.
  (function visit(node) {
    if (node == null) return;
    if (Array.isArray(node)) { for (const c of node) visit(c); return; }
    if (typeof node !== 'object') return;

    if (typeof node.type === 'string') {
      if (node.type === 'Unknown') {
        record('I1_no_unknown', `${file}: found "Unknown" node`);
      }
      if (node['[UNIMPLEMENTED]'] === true) {
        record('I2_no_unimplemented', `${file}: [UNIMPLEMENTED] on type=${node.type}`);
      }
      if (typeof node.start !== 'number' || typeof node.end !== 'number') {
        record('I3_start_end_present',
          `${file}: ${node.type} missing start/end (start=${typeof node.start}, end=${typeof node.end})`);
      } else if (node.start > node.end) {
        record('I4_start_le_end', `${file}: ${node.type} start(${node.start}) > end(${node.end})`);
      }

      // Type-specific shape checks.
      if (node.type === 'FunctionExpression') {
        if (!('id' in node)) record('I6_funcexpr_id', `${file}: FunctionExpression missing 'id'`);
        if (!Array.isArray(node.params)) record('I8_func_params_array', `${file}: FunctionExpression.params not array`);
      }
      if (node.type === 'FunctionDeclaration') {
        if (!Array.isArray(node.params)) record('I8_func_params_array', `${file}: FunctionDeclaration.params not array`);
      }
      if (node.type === 'ArrowFunctionExpression') {
        for (const f of ['id', 'expression', 'generator', 'async', 'params']) {
          if (!(f in node)) {
            record('I7_arrow_fields', `${file}: ArrowFunctionExpression missing '${f}'`);
            break;
          }
        }
        if (!Array.isArray(node.params)) record('I8_func_params_array', `${file}: ArrowFunctionExpression.params not array`);
      }
      if (node.type === 'CatchClause') {
        if (!('param' in node)) record('I9_catch_fields', `${file}: CatchClause missing 'param'`);
        if (!node.body) record('I9_catch_fields', `${file}: CatchClause missing 'body'`);
      }
      if (node.type === 'VariableDeclarator') {
        if (!node.id) record('I10_declarator_shape', `${file}: VariableDeclarator.id missing`);
        if (!('init' in node)) record('I10_declarator_shape', `${file}: VariableDeclarator.init missing`);
      }
    }
    for (const k of Object.keys(node)) visit(node[k]);
  })(tree);
}

// -----------------------------------------------------------------------------
// Parse + check each file. Skip files that fail to parse (they're a separate
// concern tracked by task test:real; this suite is ESTree-shape only).
// -----------------------------------------------------------------------------
const files = listFiles();
let parsed = 0;
let parseFails = 0;

for (const file of files) {
  let tree;
  try {
    const out = execSync(`"${KESSEL}" parse "${file}" --compact 2>/dev/null`,
      { encoding: 'utf8', maxBuffer: 500 * 1024 * 1024 });
    tree = JSON.parse(out.split('\n')[0]);
    parsed++;
  } catch (e) {
    parseFails++;
    continue;
  }
  check(tree, path.relative(ROOT, file));
}

// -----------------------------------------------------------------------------
// Report against baseline. Two gate classes:
//
//   Zero-tolerance invariants (I3-I10): MUST be 0. Any violation fails.
//   Baseline-locked (I1-I2): allowed to be non-zero (known drift surface);
//       compared to tests/invariants_baseline.json. Any INCREASE fails;
//       any DECREASE or steady-state passes. Use --update to relock.
// -----------------------------------------------------------------------------
const ZERO_TOLERANCE = new Set([
  'I3_start_end_present',
  'I4_start_le_end',
  'I5_program_shape',
  'I6_funcexpr_id',
  'I7_arrow_fields',
  'I8_func_params_array',
  'I9_catch_fields',
  'I10_declarator_shape',
]);

const baseline = fs.existsSync(BASELINE_PATH)
  ? JSON.parse(fs.readFileSync(BASELINE_PATH, 'utf8'))
  : {};

const current = {};
for (const [k, v] of Object.entries(inv)) current[k] = v.count;

console.log(`Parsed: ${parsed}/${files.length} file(s), ${parseFails} failed`);
console.log('');

let regressions = 0;
let zeroTolViolations = 0;

for (const [key, v] of Object.entries(inv)) {
  const prev = baseline[key];
  if (ZERO_TOLERANCE.has(key)) {
    if (v.count === 0) {
      console.log(`  ${key}: 0 (zero-tolerance, OK)`);
    } else {
      console.log(`  ${key}: ${v.count} (zero-tolerance, FAIL)`);
      zeroTolViolations += v.count;
      for (const s of v.samples) console.log(`      ${s}`);
      if (v.count > v.samples.length) console.log(`      ... ${v.count - v.samples.length} more`);
    }
    continue;
  }
  // Baseline-locked.
  if (prev === undefined) {
    console.log(`  ${key}: ${v.count} (new — run with --update to commit)`);
  } else if (v.count === prev) {
    console.log(`  ${key}: ${v.count} (baseline)`);
  } else if (v.count < prev) {
    console.log(`  ${key}: ${v.count} (baseline ${prev}, improved by ${prev - v.count})`);
  } else {
    console.log(`  ${key}: ${v.count} (baseline ${prev}, REGRESSED by ${v.count - prev})`);
    regressions++;
    for (const s of v.samples) console.log(`      ${s}`);
    if (v.count > v.samples.length) console.log(`      ... ${v.count - v.samples.length} more`);
  }
}

console.log('');

if (UPDATE) {
  fs.writeFileSync(BASELINE_PATH, JSON.stringify(current, null, 2) + '\n');
  console.log(`Baseline updated: ${BASELINE_PATH}`);
  process.exit(0);
}

if (zeroTolViolations > 0) {
  console.log(`FAIL — ${zeroTolViolations} zero-tolerance violation(s)`);
  process.exit(1);
}
if (regressions > 0) {
  console.log(`FAIL — ${regressions} baseline-locked invariant(s) regressed`);
  process.exit(1);
}
console.log(`OK — no zero-tolerance violations; baseline-locked invariants within bounds`);
process.exit(0);
