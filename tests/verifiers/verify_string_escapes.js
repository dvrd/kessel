#!/usr/bin/env node
// Verify that Kessel's StringLiteral.value matches OXC's Literal.value
// after escape-decoding. Walks both trees looking for literal strings and
// compares values one-to-one, in source order.
//
// Usage: node verify_string_escapes.js <file.js>
// Exit 0 on success, 1 on any mismatch or tooling failure.

const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

const file = process.argv[2];
if (!file) {
  console.error('Usage: verify_string_escapes.js <file.js>');
  process.exit(2);
}

const kesselBin = path.resolve(__dirname, '../../bin/kessel');
const oxcBin    = path.resolve(__dirname, '../../bench/oxc_compare/target/release/oxc_cli_equiv');
if (!fs.existsSync(kesselBin)) { console.error('missing', kesselBin); process.exit(2); }
if (!fs.existsSync(oxcBin))    { console.error('missing', oxcBin);    process.exit(2); }

// --- Kessel JSON: strip `[ ... ]` / `{ ... }` placeholders so JSON.parse works.
// Collect strings we CAN see in the top-level tree. Strings inside truncated
// subtrees are invisible here, but for the verifier's purpose (detecting
// escape bugs) any one reachable literal is enough to see the bug shape.
const kRaw = execSync(`${kesselBin} parse --json --compact "${file}"`, { encoding: 'utf8', maxBuffer: 500*1024*1024 });
// `--compact` output: JSON on line 1, then any number of diagnostic/stat
// lines. Take line 1 exactly — anything after it is not part of the JSON.
// (Legacy `{ ... }` / `[ ... ]` placeholders removed; no longer strip them.)
const kBody = kRaw.split('\n')[0];
let kessel;
try { kessel = JSON.parse(kBody); }
catch (e) { console.error('kessel json parse failed:', e.message); process.exit(2); }

// --- OXC JSON: full tree, no placeholders.
const oxcRaw = execSync(`${oxcBin} "${file}"`, { encoding: 'utf8', maxBuffer: 500*1024*1024 });
const oxc = JSON.parse(oxcRaw.split('\nParse errors:')[0]);

// Walk a node and collect every string literal (raw starts with '"' or "'").
// `(node, acc)` pushes `{ value, raw }` in source order into acc.
function walk(node, acc) {
  if (node == null) return;
  if (Array.isArray(node)) { for (const c of node) walk(c, acc); return; }
  if (typeof node !== 'object') return;
  if (node.type === 'Literal' &&
      typeof node.value === 'string' &&
      typeof node.raw === 'string' &&
      (node.raw.startsWith('"') || node.raw.startsWith("'"))) {
    acc.push({ value: node.value, raw: node.raw });
  }
  for (const k of Object.keys(node)) {
    const v = node[k];
    if (v && typeof v === 'object') walk(v, acc);
  }
}

const kStrings = [];
const oStrings = [];
walk(kessel, kStrings);
walk(oxc, oStrings);

// Kessel's reachable tree is a subset of OXC's (truncated subtrees are
// invisible). Align by walking OXC strings and finding the next Kessel string
// whose `raw` matches — that yields the correct pairing for escape comparison.
let ki = 0;
let mismatches = 0;
let compared = 0;
for (const o of oStrings) {
  // Skip forward in Kessel until raw matches.
  while (ki < kStrings.length && kStrings[ki].raw !== o.raw) ki++;
  if (ki >= kStrings.length) break;
  const k = kStrings[ki++];
  compared++;
  if (k.value !== o.value) {
    mismatches++;
    if (mismatches <= 10) {
      console.error(`  MISMATCH raw=${JSON.stringify(k.raw)}`);
      console.error(`    kessel=${JSON.stringify(k.value)}`);
      console.error(`    oxc   =${JSON.stringify(o.value)}`);
    }
  }
}

console.log(`${path.basename(file)}: compared=${compared} mismatches=${mismatches} (kessel-visible=${kStrings.length}, oxc-total=${oStrings.length})`);
process.exit(mismatches === 0 ? 0 : 1);
