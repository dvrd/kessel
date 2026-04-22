#!/usr/bin/env node
// Position-containment invariant: for every parent->child edge in the AST,
// `child.start >= parent.start && child.end <= parent.end`.
//
// This is a zero-tolerance structural invariant. Violations silently corrupt
// source maps, `eslint` auto-fix ranges, bundler-level dead-code elimination,
// and every downstream tool that slices the source by AST offsets.
//
// Baseline-locked across the 467-file real-world corpus (so we can merge
// this gate immediately without blocking on parser fixes), with a hard
// zero-tolerance check for single-file runs (useful in regression tests).
//
// Usage:
//   node tests/verifiers/verify_position_containment.js              # corpus
//   node tests/verifiers/verify_position_containment.js <file.js>    # single
//   node tests/verifiers/verify_position_containment.js --update     # relock
//
// Exit 0 if within baseline; 1 on any regression.

'use strict';
const fs = require('fs');
const path = require('path');
const { parseCorpusParallel } = require('./_corpus_parallel');

const ROOT = path.resolve(__dirname, '../..');
const KESSEL = path.join(ROOT, 'bin/kessel');
const BENCH_ROOT = path.join(ROOT, 'bench/real_world');
const BASELINE_PATH = path.join(ROOT, 'tests/baselines/position_containment_baseline.json');

const UPDATE = process.argv.includes('--update');
const singleFile = process.argv.slice(2).find(
  a => !a.startsWith('--') && (a.endsWith('.js') || a.endsWith('.mjs'))
);

// Field names that carry child nodes we should check against the parent span.
// Every ESTree child slot we've seen in Kessel output. Kept conservative:
// positional-only fields (e.g. `value` on Property) + generic "body" etc.
// String / number / bool fields are naturally skipped by the visitor.

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

// Walk a tree and call `visit(parent, child, path)` for every parent->child
// edge where both sides have numeric start/end. Root has parent=null.
function walkEdges(tree, visit) {
  (function rec(node, parent, p) {
    if (node == null) return;
    if (Array.isArray(node)) {
      for (let i = 0; i < node.length; i++) rec(node[i], parent, `${p}[${i}]`);
      return;
    }
    if (typeof node !== 'object') return;
    if (parent && typeof node.start === 'number' && typeof node.end === 'number'
      && typeof parent.start === 'number' && typeof parent.end === 'number') {
      visit(parent, node, p);
    }
    const nextParent = (typeof node.start === 'number' && typeof node.end === 'number') ? node : parent;
    for (const k of Object.keys(node)) {
      if (k === 'start' || k === 'end' || k === 'type' || k === 'loc' || k === 'range') continue;
      // Skip primitive fields and Kessel-emitted comment siblings that are
      // not strictly children in the ESTree sense (they carry their own
      // spans but are NOT contained in the Program node).
      if (k === 'comments' && (node.type === 'Program' || node.type === undefined)) continue;
      rec(node[k], nextParent, `${p}.${k}`);
    }
  })(tree, null, 'program');
}

(async () => {
const files = listFiles();
const violations = []; // { file, path, parent, child, parentSpan, childSpan }
let parsed, parseFails;

const result = await parseCorpusParallel(files, {
  kesselBin: KESSEL,
  onFile: (tree, file) => {
    walkEdges(tree, (parent, child, p) => {
      if (child.start < parent.start || child.end > parent.end) {
        violations.push({
          file: path.relative(ROOT, file),
          path: p,
          parent: parent.type,
          child: child.type,
          parentSpan: [parent.start, parent.end],
          childSpan: [child.start, child.end],
        });
      }
    });
  },
});
parsed = result.parsed;
parseFails = result.parseFails;

console.log(`Parsed: ${parsed}/${files.length} file(s), ${parseFails} failed`);
console.log('');

// Aggregate by (parent, child, field) to show the bug classes not individual
// violations (they tend to repeat across files).
const byClass = new Map();
for (const v of violations) {
  // Strip array indices to collapse "declarations[0].id" and "declarations[7].id"
  const fieldPath = v.path.replace(/\[\d+\]/g, '[]');
  const key = `${v.parent}.${fieldPath.split('.').slice(-2).join('.')} -> ${v.child}`;
  const bucket = byClass.get(key) || { count: 0, sample: null };
  bucket.count++;
  if (!bucket.sample) bucket.sample = v;
  byClass.set(key, bucket);
}

const byClassObj = {};
for (const [k, v] of byClass) byClassObj[k] = v.count;

const baseline = fs.existsSync(BASELINE_PATH)
  ? JSON.parse(fs.readFileSync(BASELINE_PATH, 'utf8'))
  : null;

if (UPDATE || baseline === null) {
  fs.writeFileSync(BASELINE_PATH, JSON.stringify({
    total_violations: violations.length,
    by_class: byClassObj,
  }, null, 2) + '\n');
  console.log(`Baseline ${baseline === null ? 'created' : 'updated'}: ${BASELINE_PATH}`);
  console.log(`Total violations: ${violations.length} across ${byClass.size} bug-class(es)`);
  if (violations.length > 0) {
    console.log('\nTop bug classes:');
    const top = [...byClass.entries()].sort((a, b) => b[1].count - a[1].count).slice(0, 20);
    for (const [k, v] of top) {
      console.log(`  ${v.count}x  ${k}`);
      const s = v.sample;
      console.log(`        e.g. ${s.file} at ${s.path}: parent=${s.parentSpan.join('..')}  child=${s.childSpan.join('..')}`);
    }
  }
  process.exit(0);
}

// Compare current to baseline.
const baselineTotal = baseline.total_violations || 0;
const regressions = violations.length - baselineTotal;
console.log(`Total violations: ${violations.length} (baseline ${baselineTotal})`);

if (singleFile) {
  // Single-file mode: zero-tolerance, useful as a regression harness.
  if (violations.length > 0) {
    console.log('FAIL (single-file mode, zero-tolerance):');
    for (const v of violations.slice(0, 20)) {
      console.log(`  ${v.file} ${v.path}: parent=${v.parent}[${v.parentSpan.join('..')}]  child=${v.child}[${v.childSpan.join('..')}]`);
    }
    if (violations.length > 20) console.log(`  ... ${violations.length - 20} more`);
    process.exit(1);
  }
  console.log('OK (single-file, zero violations)');
  process.exit(0);
}

// Corpus mode: compare to baseline.
if (regressions > 0) {
  console.log(`REGRESSED by ${regressions} violation(s).`);
  // Show new classes.
  const newClasses = [];
  for (const [k, v] of byClass) {
    if (!(k in (baseline.by_class || {}))) newClasses.push([k, v.count, v.sample]);
  }
  if (newClasses.length) {
    console.log('New bug classes:');
    for (const [k, c, s] of newClasses.slice(0, 10)) {
      console.log(`  +${c}x  ${k}`);
      if (s) console.log(`        e.g. ${s.file} at ${s.path}`);
    }
  }
  process.exit(1);
}
if (regressions < 0) {
  console.log(`IMPROVED by ${-regressions} violation(s). Run with --update to relock.`);
}
console.log('OK (corpus, matches/improves baseline)');
process.exit(0);
})();
