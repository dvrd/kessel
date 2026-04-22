#!/usr/bin/env node
// Literal.raw vs Literal.value consistency gate.
//
// ESTree requires `Literal.raw` to be the EXACT source text of the literal
// and `Literal.value` to be its evaluated form. A consumer that trusts
// `value` for booleans/numbers but `raw` for anything round-tripped can
// silently break if the two disagree.
//
// Checks (per ESTree Literal shape):
//   - raw === null      : Literal for a BigInt or unrepresentable regex \u2014 skip.
//   - typeof value ==='boolean':
//       raw must be "true" or "false".
//   - value === null:
//       raw must be either "null" (NullLiteral) OR the regex-placeholder
//       case (has a `regex` field) \u2014 both are legal.
//   - typeof value === 'number':
//       Number(raw) must equal value (allowing NaN === NaN fuzz). Notable
//       exceptions: numeric-separator underscores + legacy-octal raws
//       that Number() can't parse directly.
//   - typeof value === 'string':
//       raw must start and end with matching quote (' or "), OR be a
//       template-literal quasi (raw starts with ` or $` etc). We just
//       check the quote shape; escape decoding is covered elsewhere
//       (verify_string_escapes.js).
//   - typeof value === 'bigint' (or BigInt object):
//       raw must end with 'n'.
//
// Baseline-locked on the 467-file corpus. Any class of violation that
// grows is a regression.
//
// Usage:
//   node tests/verifiers/verify_raw_value_consistency.js              # corpus
//   node tests/verifiers/verify_raw_value_consistency.js <file.js>    # single
//   node tests/verifiers/verify_raw_value_consistency.js --update     # relock
//
// Exit 0 on match/improve; 1 on regression.

'use strict';
const fs = require('fs');
const path = require('path');
const { parseCorpusParallel } = require('./_corpus_parallel');

const ROOT = path.resolve(__dirname, '../..');
const KESSEL = path.join(ROOT, 'bin/kessel');
const BENCH_ROOT = path.join(ROOT, 'bench/real_world');
const BASELINE_PATH = path.join(ROOT, 'tests/baselines/raw_value_baseline.json');

const UPDATE = process.argv.includes('--update');
const singleFile = process.argv.slice(2).find(
  a => !a.startsWith('--') && (a.endsWith('.js') || a.endsWith('.mjs'))
);

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

const classes = {};
function bump(cls, sample) {
  const b = classes[cls] || { count: 0, sample: null };
  b.count++;
  if (b.sample === null) b.sample = sample;
  classes[cls] = b;
}

function check(node, file) {
  if (node == null) return;
  if (Array.isArray(node)) { for (const c of node) check(c, file); return; }
  if (typeof node !== 'object') return;

  if (node.type === 'Literal') {
    const { value, raw, regex, bigint } = node;
    if (typeof raw === 'string') {
      if (typeof value === 'boolean') {
        if (raw !== 'true' && raw !== 'false') {
          bump('boolean raw != true/false',
            `${file}: Literal value=${value} raw=${JSON.stringify(raw)}`);
        }
      } else if (value === null) {
        // Three legal shapes for value===null:
        //   1. real NullLiteral — raw === "null"
        //   2. regex placeholder — regex field present (JSON can't encode RegExp)
        //   3. BigInt placeholder — raw ends with "n" AND bigint field present.
        //      If raw ends with "n" but there's no `bigint` field, it's a
        //      genuine ESTree compliance gap (consumer has no way to tell
        //      BigInt from null).
        if (raw === 'null' || regex) {
          // Legal.
        } else if (/n$/.test(raw)) {
          if (bigint === undefined) {
            bump('BigInt literal missing "bigint" field',
              `${file}: Literal raw=${JSON.stringify(raw)} value=null no bigint field`);
          }
          // otherwise legal BigInt placeholder.
        } else {
          bump('null raw != "null" and no regex/bigint',
            `${file}: Literal value=null raw=${JSON.stringify(raw)}`);
        }
      } else if (typeof value === 'number') {
        // Cheap sanity: Number(raw) should equal value. Strip numeric
        // separators first; fall through for legacy-octal / exotic raws.
        const stripped = raw.replace(/_/g, '');
        const parsed = Number(stripped);
        // Allow BOTH-NaN (NaN !== NaN) as a pass.
        const numMatch = (Number.isNaN(parsed) && Number.isNaN(value)) ||
                         parsed === value ||
                         // Legacy octal: raw like "0755" → 493; Number("0755")
                         // === 755 in strict ECMA but we allow the octal value.
                         (/^0[0-7]+$/.test(stripped) && parseInt(stripped, 8) === value);
        if (!numMatch) {
          bump('number Number(raw) != value',
            `${file}: Literal raw=${JSON.stringify(raw)} -> Number=${parsed} but value=${value}`);
        }
      } else if (typeof value === 'string') {
        const first = raw[0];
        const last = raw[raw.length - 1];
        if (first !== "'" && first !== '"') {
          bump('string raw does not start with quote',
            `${file}: Literal raw=${JSON.stringify(raw.slice(0, 40))}`);
        } else if (first !== last) {
          bump('string raw unmatched quote',
            `${file}: Literal raw=${JSON.stringify(raw.slice(0, 40))}`);
        }
      } else if (typeof value === 'bigint' || bigint !== undefined) {
        if (!/n$/.test(raw)) {
          bump('bigint raw does not end with "n"',
            `${file}: Literal raw=${JSON.stringify(raw)}`);
        }
      }
    }
  }
  for (const k of Object.keys(node)) check(node[k], file);
}

(async () => {
const files = listFiles();
let parsed, parseFails;

const result = await parseCorpusParallel(files, {
  kesselBin: KESSEL,
  onFile: (tree, file) => check(tree, path.relative(ROOT, file)),
});
parsed = result.parsed;
parseFails = result.parseFails;

console.log(`Parsed: ${parsed}/${files.length} file(s), ${parseFails} failed`);
const current = {};
for (const [k, v] of Object.entries(classes)) current[k] = v.count;

const baseline = fs.existsSync(BASELINE_PATH)
  ? JSON.parse(fs.readFileSync(BASELINE_PATH, 'utf8'))
  : null;

if (UPDATE || baseline === null) {
  fs.writeFileSync(BASELINE_PATH, JSON.stringify(current, null, 2) + '\n');
  console.log(`Baseline ${baseline === null ? 'created' : 'updated'}: ${BASELINE_PATH}`);
  for (const [k, b] of Object.entries(classes)) {
    console.log(`  ${b.count}x  ${k}`);
    if (b.sample) console.log(`        e.g. ${b.sample}`);
  }
  if (Object.keys(classes).length === 0) console.log('  (no violations)');
  process.exit(0);
}

if (singleFile) {
  if (Object.keys(classes).length > 0) {
    console.log('FAIL (single-file, zero-tolerance):');
    for (const [k, b] of Object.entries(classes)) {
      console.log(`  ${b.count}x  ${k}`);
      if (b.sample) console.log(`        e.g. ${b.sample}`);
    }
    process.exit(1);
  }
  console.log('OK (single-file, zero violations)');
  process.exit(0);
}

let regressions = 0;
let improvements = 0;
const seen = new Set();
for (const [k, c] of Object.entries(current)) {
  seen.add(k);
  const prev = baseline[k];
  if (prev === undefined) { console.log(`  +${c}x  ${k} (NEW)`); regressions++; }
  else if (c > prev)     { console.log(`  +${c - prev}  ${k}: ${prev} -> ${c} (regressed)`); regressions++; }
  else if (c < prev)     { console.log(`  -${prev - c}  ${k}: ${prev} -> ${c} (improved)`); improvements++; }
  else                   { console.log(`       ${k}: ${c} (baseline)`); }
}
for (const [k, prev] of Object.entries(baseline)) {
  if (!seen.has(k)) { console.log(`  -${prev}  ${k}: ${prev} -> 0 (class gone)`); improvements++; }
}

if (regressions > 0) { console.log(`REGRESSIONS in ${regressions} class(es).`); process.exit(1); }
if (improvements > 0) console.log(`${improvements} class(es) improved. Run with --update to relock.`);
console.log('OK (corpus)');
process.exit(0);
})();
