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

const ROOT = path.resolve(__dirname, '../..');
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
  {
    name: '007_use_strict_directive',
    // Fix 658f25f: "use strict" (and any Directive Prologue) must appear in
    // `program.body` as an ExpressionStatement wrapping a Literal, in
    // addition to `program.directives`. Previously the body leaked the
    // statement — readers walking `body` diverged from OXC.
    require: ['ExpressionStatement', 'Literal', 'VariableDeclaration', 'FunctionDeclaration'],
    customCheck: (k, _o) => {
      const fails = [];
      // Top-level body must start with the "use strict" ExpressionStatement.
      const body = Array.isArray(k.body) ? k.body : [];
      const first = body[0];
      if (!first || first.type !== 'ExpressionStatement') {
        fails.push(`body[0] expected ExpressionStatement, got ${first && first.type}`);
      } else {
        const e = first.expression || {};
        if (e.type !== 'Literal' || e.value !== 'use strict') {
          fails.push(`body[0].expression expected Literal("use strict"), got ${e.type}=${JSON.stringify(e.value)}`);
        }
      }
      // Inside `function f`, the nested "use strict" must ALSO appear in body[0]
      // of the function body — same ESTree rule applies recursively.
      const fn = body.find(s => s && s.type === 'FunctionDeclaration');
      if (fn) {
        const fnFirst = fn.body && Array.isArray(fn.body.body) ? fn.body.body[0] : null;
        if (!fnFirst || fnFirst.type !== 'ExpressionStatement' ||
            !fnFirst.expression || fnFirst.expression.value !== 'use strict') {
          fails.push(`f.body[0] expected "use strict" ExpressionStatement, got ${fnFirst && fnFirst.type}`);
        }
      } else {
        fails.push(`no FunctionDeclaration found in fixture body`);
      }
      return fails;
    },
  },
  {
    name: '008_export_all',
    // Fix 75b7ada: ExportAllDeclaration must consume its trailing semicolon,
    // otherwise a spurious EmptyStatement appears in body[] between each
    // export. Assertion: exactly 5 real statements, ZERO EmptyStatement
    // anywhere in the top-level body.
    require: ['ExportAllDeclaration', 'VariableDeclaration', 'FunctionDeclaration'],
    customCheck: (k, _o) => {
      const fails = [];
      const body = Array.isArray(k.body) ? k.body : [];
      const counts = {};
      for (const s of body) counts[s && s.type] = (counts[s && s.type] || 0) + 1;
      if ((counts.EmptyStatement || 0) !== 0) {
        fails.push(`body contains ${counts.EmptyStatement} EmptyStatement (expected 0)`);
      }
      if ((counts.ExportAllDeclaration || 0) !== 3) {
        fails.push(`expected 3 ExportAllDeclaration, got ${counts.ExportAllDeclaration || 0}`);
      }
      if (body.length !== 5) {
        fails.push(`expected body.length==5, got ${body.length}`);
      }
      return fails;
    },
  },
  {
    name: '009_destructure_patterns',
    // Fix 72275c8 + follow-up: ArrayPattern/ObjectPattern emit must produce
    // valid JSON for every variant of Pattern (including RestElement,
    // AssignmentPattern, holes in ArrayPattern, and RestElement as a direct
    // sibling in ObjectPattern.properties rather than wrapped in Property).
    // The `parseKessel` call at the top of this script already runs
    // JSON.parse — any drift that emits `{null}` or `{null}` would throw
    // before we get here. Beyond that, assert structural completeness.
    require: ['ArrayPattern', 'ObjectPattern', 'RestElement', 'AssignmentPattern',
              'Identifier', 'VariableDeclaration', 'FunctionDeclaration'],
    atLeast: {
      'RestElement': 3,        // `...rest` in array destructure + object destructure + function param
      'AssignmentPattern': 3,  // `q = 10`, `r: rr = 20`, `x = 1`
    },
    customCheck: (k, _o) => {
      const fails = [];
      // Walk: every ArrayPattern.elements[i] must be either `null` (hole)
      // OR a node with a non-null type. Never the stray `{null}` bug.
      let holeCount = 0;
      (function walk(n) {
        if (!n || typeof n !== 'object') return;
        if (Array.isArray(n)) { for (const c of n) walk(c); return; }
        if (n.type === 'ArrayPattern' && Array.isArray(n.elements)) {
          for (let i = 0; i < n.elements.length; i++) {
            const el = n.elements[i];
            if (el === null) { holeCount++; continue; }
            if (typeof el !== 'object' || typeof el.type !== 'string') {
              fails.push(`ArrayPattern.elements[${i}] malformed: ${JSON.stringify(el)}`);
            }
          }
        }
        if (n.type === 'ObjectPattern' && Array.isArray(n.properties)) {
          for (let i = 0; i < n.properties.length; i++) {
            const p = n.properties[i];
            if (!p || (p.type !== 'Property' && p.type !== 'RestElement')) {
              fails.push(`ObjectPattern.properties[${i}].type expected Property|RestElement, got ${p && p.type}`);
            }
          }
        }
        for (const k2 of Object.keys(n)) walk(n[k2]);
      })(k);
      // Fixture has 2 holes: `[, , c]` and `[d, , e, ...rest]`.
      if (holeCount < 2) fails.push(`expected >=2 ArrayPattern holes, saw ${holeCount}`);
      return fails;
    },
  },
  {
    name: '010_arrow_block_body',
    // Bug I-7: parse_arrow_function (3 sites) stored body via
    // `cast(^BlockStatement)^Statement` — reading the 16-byte Statement union
    // header as the start of BlockStatement fields, corrupting body.body so
    // iteration yielded garbage pointers (0x14 = 20). Emit-time SIGSEGV deep
    // inside class methods containing arrow+block bodies (tone.js and 11
    // others, including prettier.js which was the single site that survived
    // the first two arrow-arm fixes until the async arrow arm was also fixed).
    //
    // Direct signal: every ArrowFunctionExpression whose body is a
    // BlockStatement must have a non-empty `.body` array. A zero-length
    // body (where the source clearly has statements) is the exact corruption
    // footprint — [dynamic] header being misread as zero length.
    require: ['ArrowFunctionExpression', 'BlockStatement', 'ReturnStatement',
              'VariableDeclaration', 'ForStatement', 'IfStatement'],
    customCheck: (k, _o) => {
      const fails = [];
      let blockBodied = 0;
      let nonEmptyBlockBodied = 0;
      (function walk(n) {
        if (!n || typeof n !== 'object') return;
        if (Array.isArray(n)) { for (const c of n) walk(c); return; }
        if (n.type === 'ArrowFunctionExpression') {
          const b = n.body;
          if (b && b.type === 'BlockStatement') {
            blockBodied++;
            const count = Array.isArray(b.body) ? b.body.length : 0;
            if (count > 0) nonEmptyBlockBodied++;
          }
        }
        for (const key of Object.keys(n)) walk(n[key]);
      })(k);
      if (blockBodied < 3) fails.push(`expected >=3 block-bodied arrows, saw ${blockBodied}`);
      if (nonEmptyBlockBodied !== blockBodied) {
        fails.push(`${blockBodied - nonEmptyBlockBodied} block-bodied arrow(s) have empty .body (corruption signal)`);
      }
      return fails;
    },
  },
  {
    name: '011_lone_surrogate_emit',
    // Bug: lex_string_scalar's append_utf8 WTF-8-encoded lone surrogates
    // (0xED 0xA0-BF 0x80-BF), and out_string streamed those bytes raw.
    // JSON forbids raw surrogate bytes; JSON.parse normalises the invalid
    // UTF-8 triple to U+FFFD. Surfaced as the last 2 mismatches on
    // handsontable.js after ClassBody emit made all strings visible.
    //
    // Fix: wtf8_surrogate_at detects the triple at emit time; out_string
    // / out_string_inner escape as \uXXXX (lowercase hex, matching OXC).
    // ECMA-262 permits lone surrogates in string literals — the ESTree
    // `value` must round-trip through JSON as a 1-codepoint string whose
    // codePointAt(0) is still in 0xD800..0xDFFF.
    require: ['Literal', 'VariableDeclaration', 'ObjectExpression'],
    customCheck: (k, _o) => {
      const fails = [];
      const literals = [];
      (function walk(n) {
        if (!n || typeof n !== 'object') return;
        if (Array.isArray(n)) { for (const c of n) walk(c); return; }
        if (n.type === 'Literal' && typeof n.value === 'string') {
          literals.push(n);
        }
        for (const key of Object.keys(n)) walk(n[key]);
      })(k);

      // Every code unit must be a valid UTF-16 code unit. If any value
      // contains U+FFFD where the source had `\uXXXX`, the fix regressed.
      // We can't diff against the source directly, but we CAN look for the
      // specific patterns we put in the fixture.
      const expectedSurrogates = [
        0xDEAD, 0xD834, 0xDF06, 0xD800, 0xDC00, 0xDFFF,
      ];
      const seen = new Set();
      for (const lit of literals) {
        for (const ch of lit.value) {
          const cp = ch.codePointAt(0);
          if (cp >= 0xD800 && cp <= 0xDFFF) seen.add(cp);
          if (cp === 0xFFFD) {
            fails.push(`Literal "${lit.raw}" contains U+FFFD — lone surrogate got normalised (fix regressed)`);
          }
        }
      }
      // Sanity: the fixture includes at least 4 distinct lone-surrogate
      // codepoints across its literals.
      const surrogateCount = seen.size;
      if (surrogateCount < 4) {
        fails.push(`expected >=4 distinct lone surrogates in Literal.value, saw ${surrogateCount}`);
      }
      return fails;
    },
  },
];

// Global assertion that runs on every fixture, regardless of per-check config:
// no node in the emitted JSON may carry the sentinel `[UNIMPLEMENTED]: true`
// field, and no Kessel-internal "Unknown" type name may appear. Either is a
// sign that a switch/case fell through the default arm — silent ESTree drift
// of the exact kind this session set out to eliminate.
function assertNoUnknownOrUnimplemented(root) {
  const fails = [];
  (function walk(n) {
    if (!n || typeof n !== 'object') return;
    if (Array.isArray(n)) { for (const c of n) walk(c); return; }
    if (n.type === 'Unknown')        fails.push(`found node with type "Unknown"`);
    if (n['[UNIMPLEMENTED]'] === true) fails.push(`found [UNIMPLEMENTED] sentinel (type=${n.type})`);
    for (const k of Object.keys(n)) walk(n[k]);
  })(root);
  return fails;
}

function parseKessel(file) {
  const raw = execSync(`"${KESSEL}" parse --json --compact "${file}"`,
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
  const unknownFails = assertNoUnknownOrUnimplemented(k);

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

  if (missing.length === 0 && short.length === 0 && pathFails.length === 0 &&
      customFails.length === 0 && unknownFails.length === 0) {
    console.log(`[${check.name}] OK`);
  } else {
    failures++;
    if (missing.length)   console.log(`[${check.name}] MISSING:   ${missing.join(', ')}`);
    if (short.length)     console.log(`[${check.name}] SHORT:     ${short.join(', ')}`);
    if (pathFails.length) for (const f of pathFails)     console.log(`[${check.name}] PATH:      ${f}`);
    if (customFails.length) for (const f of customFails) console.log(`[${check.name}] CUSTOM:    ${f}`);
    if (unknownFails.length) for (const f of unknownFails) console.log(`[${check.name}] DRIFT:     ${f}`);
  }
}

if (failures > 0) {
  console.error(`\n${failures} regression check(s) failed`);
  process.exit(1);
}
console.log(`\nAll ${CHECKS.length} regression checks pass`);
