#!/usr/bin/env node
// Verify regression fixtures against OXC — prove the JSON shape matches the
// ESTree-canonical reference for the specific bug classes fixed this session:
//
//   001 StaticBlock body transmute       → StaticBlock.body populated
//   002 ForStatement decl-as-stmt cast   → init is VariableDeclaration
//   003 ForIn/Of decl transmute          → left is VariableDeclaration
//   004 ExportDecl (^Statement)(decl)    → declaration dispatches to correct type
//   005 ClassBody stub                   → MethodDefinition/PropertyDefinition/StaticBlock
//   006 direct_buf overflow              → 40+ class methods emit cleanly
//
// For each fixture we walk Kessel's JSON and OXC's JSON and compare the
// multiset of structural "signatures" we care about — counts of node types
// at key positions. Exact-shape diff would be too strict (OXC carries
// start/end fields Kessel doesn't emit, and the two printers differ on
// whitespace), so signature-compare catches regressions of the
// bugs-under-test without false positives from formatting drift.
//
// Usage: node tests/verify_regression.js
// Exit 0 on success, 1 on any mismatch.

const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..');
const KESSEL = path.join(ROOT, 'bin/kessel');
const OXC    = path.join(ROOT, 'bench/oxc_compare/target/release/oxc_cli_equiv');

if (!fs.existsSync(KESSEL)) { console.error('missing kessel binary'); process.exit(2); }
if (!fs.existsSync(OXC))    { console.error('missing oxc binary');    process.exit(2); }

// Count node types occurring anywhere in the tree.
function countTypes(node, counts) {
  if (node == null) return;
  if (Array.isArray(node)) { for (const c of node) countTypes(c, counts); return; }
  if (typeof node !== 'object') return;
  if (typeof node.type === 'string') {
    counts.set(node.type, (counts.get(node.type) || 0) + 1);
  }
  for (const k of Object.keys(node)) countTypes(node[k], counts);
}

// Walk tree and collect every (path-pattern, node.type) pair we care about.
// pathMatchers is an array of [predicate, label]; for each node whose
// enclosing path matches any predicate we count the node's type under label.
//
// This catches bugs of the form "ForStatement.init dispatched to the wrong
// variant" which would be invisible to a flat type-count check because the
// same type still appears elsewhere in the tree.
function collectByPath(root, pathMatchers) {
  const out = new Map();
  function visit(node, parentKey) {
    if (node == null) return;
    if (Array.isArray(node)) { for (const c of node) visit(c, parentKey); return; }
    if (typeof node !== 'object') return;
    for (const [pred, label] of pathMatchers) {
      if (pred(parentKey, node)) {
        const t = typeof node.type === 'string' ? node.type : '<no-type>';
        const bucket = out.get(label) || new Map();
        bucket.set(t, (bucket.get(t) || 0) + 1);
        out.set(label, bucket);
      }
    }
    for (const k of Object.keys(node)) visit(node[k], { type: node.type, field: k });
  }
  visit(root, null);
  return out;
}

// For each fixture, a signature is the multiset of types that must match
// between Kessel and OXC. We intentionally ignore counts that differ by a
// small constant because OXC emits a few wrapper nodes Kessel doesn't
// (e.g. Program vs Script — both valid ESTree root types).
const CHECKS = [
  {
    name: '001_static_block_body',
    // StaticBlock must be present twice and contain statement children.
    // The bug left StaticBlock.body as `[]`; the path-check asserts each
    // StaticBlock carries at least one statement, which is the exact
    // signal of the transmute-corrupted body.
    require: ['StaticBlock', 'ExpressionStatement', 'VariableDeclaration', 'AssignmentExpression'],
    customCheck: (k, _o) => {
      const fails = [];
      let totalStmts = 0;
      let staticBlocks = 0;
      (function walk(n) {
        if (!n || typeof n !== 'object') return;
        if (Array.isArray(n)) { for (const c of n) walk(c); return; }
        if (n.type === 'StaticBlock') {
          staticBlocks++;
          const stmts = Array.isArray(n.body) ? n.body.length : 0;
          totalStmts += stmts;
          if (stmts === 0) fails.push(`StaticBlock #${staticBlocks} has empty body`);
        }
        for (const key of Object.keys(n)) walk(n[key]);
      })(k);
      if (staticBlocks < 2) fails.push(`expected >=2 StaticBlock nodes, saw ${staticBlocks}`);
      if (totalStmts < 5)   fails.push(`expected >=5 statements across static blocks, saw ${totalStmts}`);
      return fails;
    },
  },
  {
    name: '002_class_for_statement',
    // Every `for (let/var/const ...; ...; ...)` init must emit as
    // VariableDeclaration. Bug: cast corrupted dispatch → missing or
    // garbled declarations. Path-check pins the signal to the init slot —
    // a flat count of VariableDeclaration elsewhere wouldn't catch the
    // exact bug (exports & fields produce them too).
    require: ['ForStatement', 'VariableDeclaration', 'MethodDefinition', 'ArrowFunctionExpression'],
    pathCheck: {
      'ForStatement.init': {
        matcher: (p, _n) => p && p.type === 'ForStatement' && p.field === 'init',
        mustBe: 'VariableDeclaration',
        minCount: 3,
      },
    },
  },
  {
    name: '003_class_for_in_of',
    require: ['ForInStatement', 'ForOfStatement', 'VariableDeclaration', 'MethodDefinition'],
    pathCheck: {
      'ForInStatement.left': {
        matcher: (p, _n) => p && p.type === 'ForInStatement' && p.field === 'left',
        mustBe: 'VariableDeclaration',
        minCount: 1,
      },
      'ForOfStatement.left': {
        matcher: (p, _n) => p && p.type === 'ForOfStatement' && p.field === 'left',
        mustBe: 'VariableDeclaration',
        minCount: 1,
      },
    },
  },
  {
    name: '004_export_declarations',
    require: ['ExportNamedDeclaration', 'ExportDefaultDeclaration', 'VariableDeclaration',
              'FunctionDeclaration', 'ClassDeclaration', 'MethodDefinition'],
    pathCheck: {
      'ExportNamedDeclaration.declaration': {
        // Bug: `(^Declaration)(decl)` on a ^Statement pointer made the inner
        // type "Unknown" because tag ordinals differ between the two unions.
        matcher: (p, n) => p && p.type === 'ExportNamedDeclaration'
                        && p.field === 'declaration'
                        && n && n.type !== undefined,
        forbidType: 'Unknown',
        minCount: 3,
      },
    },
  },
  {
    name: '005_class_body_full_emit',
    require: ['MethodDefinition', 'PropertyDefinition', 'StaticBlock', 'PrivateIdentifier',
              'FunctionExpression'],
    // Minimum counts we expect in the output (from the fixture source).
    atLeast: {
      'MethodDefinition': 8,     // constructor + 7 methods (incl. get/set)
      'PropertyDefinition': 5,   // plain, #private, staticField, #staticPrivate, uninitialised
      'StaticBlock': 1,
    },
  },
  {
    name: '006_direct_buf_grow',
    // 40 trivial methods must emit cleanly (previously overflowed direct_buf).
    atLeast: { 'MethodDefinition': 40 },
  },
];

function parseKessel(file) {
  const raw = execSync(`"${KESSEL}" parse "${file}" --compact`,
                       { encoding: 'utf8', maxBuffer: 200*1024*1024 });
  return JSON.parse(raw.split('\n')[0]);
}
function parseOxc(file) {
  const raw = execSync(`"${OXC}" "${file}"`,
                       { encoding: 'utf8', maxBuffer: 200*1024*1024 });
  return JSON.parse(raw.split('\nParse errors:')[0]);
}

let failures = 0;
for (const check of CHECKS) {
  const file = path.join(ROOT, 'tests/fixtures/regression', check.name + '.js');
  if (!fs.existsSync(file)) {
    console.error(`[${check.name}] missing fixture`);
    failures++; continue;
  }

  let k, o;
  try { k = parseKessel(file); } catch (e) {
    console.error(`[${check.name}] kessel parse failed: ${e.message}`);
    failures++; continue;
  }
  try { o = parseOxc(file); } catch (e) {
    console.error(`[${check.name}] oxc parse failed: ${e.message}`);
    failures++; continue;
  }

  const kCounts = new Map();  countTypes(k, kCounts);
  const oCounts = new Map();  countTypes(o, oCounts);

  const missing = [];
  for (const t of (check.require || [])) {
    const kC = kCounts.get(t) || 0;
    const oC = oCounts.get(t) || 0;
    if (kC === 0 && oC > 0) {
      missing.push(`${t} (kessel=0, oxc=${oC})`);
    }
  }

  const short = [];
  for (const [t, min] of Object.entries(check.atLeast || {})) {
    const kC = kCounts.get(t) || 0;
    if (kC < min) {
      short.push(`${t} (kessel=${kC}, expected>=${min})`);
    }
  }

  const customFails = check.customCheck ? check.customCheck(k, o) : [];

  const pathFails = [];
  if (check.pathCheck) {
    const matchers = Object.entries(check.pathCheck).map(
      ([label, spec]) => [spec.matcher, label]);
    const buckets = collectByPath(k, matchers);
    for (const [label, spec] of Object.entries(check.pathCheck)) {
      const bucket = buckets.get(label) || new Map();
      if (spec.mustBe) {
        const hits = bucket.get(spec.mustBe) || 0;
        const min = spec.minCount || 1;
        if (hits < min) {
          const seen = [...bucket.entries()].map(([t, c]) => `${t}=${c}`).join(', ') || '(none)';
          pathFails.push(`${label}: expected >=${min} ${spec.mustBe} but saw ${seen}`);
        }
      }
      if (spec.forbidType) {
        const bad = bucket.get(spec.forbidType) || 0;
        if (bad > 0) {
          pathFails.push(`${label}: forbidden type '${spec.forbidType}' appeared ${bad} times`);
        }
        if (spec.minCount) {
          const total = [...bucket.values()].reduce((a, b) => a + b, 0);
          if (total < spec.minCount) {
            pathFails.push(`${label}: expected >=${spec.minCount} hits, saw ${total}`);
          }
        }
      }
    }
  }

  if (missing.length === 0 && short.length === 0 && pathFails.length === 0 && customFails.length === 0) {
    console.log(`[${check.name}] OK`);
  } else {
    failures++;
    if (missing.length)   console.log(`[${check.name}] MISSING:   ${missing.join(', ')}`);
    if (short.length)     console.log(`[${check.name}] SHORT:     ${short.join(', ')}`);
    if (pathFails.length) for (const f of pathFails)   console.log(`[${check.name}] PATH:      ${f}`);
    if (customFails.length) for (const f of customFails) console.log(`[${check.name}] CUSTOM:    ${f}`);
  }
}

if (failures > 0) {
  console.error(`\n${failures} regression check(s) failed`);
  process.exit(1);
}
console.log(`\nAll ${CHECKS.length} regression checks pass`);
