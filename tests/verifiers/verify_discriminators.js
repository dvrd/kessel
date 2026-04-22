#!/usr/bin/env node
// ESTree enum-field discriminator gate.
//
// ESTree spec has a handful of string fields that MUST be drawn from a
// fixed enum. If a parser drifts here it's invisible to deep-JSON compare
// (the comparator just reports "kessel=method oxc=init" on a single node)
// but breaks every consumer that dispatches on the field.
//
// Fields checked (name, legal-set, why):
//   Property.kind               {init, get, set}                  ES Property descriptors
//   MethodDefinition.kind       {constructor, method, get, set}   ClassBody member dispatch
//   VariableDeclaration.kind    {var, let, const, using, await using}
//                                                                  Scope + TDZ rules
//   Program.sourceType          {script, module}                  Strict-by-default vs not
//   AssignmentExpression.operator
//                               {=, +=, -=, *=, /=, %=, **=,
//                                <<=, >>=, >>>=, |=, ^=, &=,
//                                ||=, &&=, ??=}
//   BinaryExpression.operator   {+, -, *, /, %, **, &, |, ^, <<, >>, >>>,
//                                ==, !=, ===, !==, <, <=, >, >=,
//                                instanceof, in}
//   LogicalExpression.operator  {&&, ||, ??}
//   UpdateExpression.operator   {++, --}
//   UnaryExpression.operator    {-, +, !, ~, typeof, void, delete}
//
// Plus a handful of "shape" discriminators where the TYPE of a child node
// must be drawn from a legal set:
//   ObjectPattern.properties[i].type    {Property, RestElement}
//   ClassBody.body[i].type              {MethodDefinition, PropertyDefinition,
//                                        StaticBlock, AccessorProperty}
//   SwitchStatement.cases[i].type       {SwitchCase}
//   ChainExpression.expression.type     {MemberExpression, CallExpression}
//
// Baseline-locked across the 467-file real-world corpus. Growing the
// baseline = regression; shrinking = improvement.
//
// Usage:
//   node tests/verifiers/verify_discriminators.js              # corpus
//   node tests/verifiers/verify_discriminators.js <file.js>    # single file (zero-tol)
//   node tests/verifiers/verify_discriminators.js --update     # relock
//
// Exit 0 on match/improve; 1 on regression (or any violation in single-file mode).

'use strict';
const fs = require('fs');
const path = require('path');
const { parseCorpusParallel } = require('./_corpus_parallel');

const ROOT = path.resolve(__dirname, '../..');
const KESSEL = path.join(ROOT, 'bin/kessel');
const BENCH_ROOT = path.join(ROOT, 'bench/real_world');
const BASELINE_PATH = path.join(ROOT, 'tests/baselines/discriminators_baseline.json');

const UPDATE = process.argv.includes('--update');
const singleFile = process.argv.slice(2).find(
  a => !a.startsWith('--') && (a.endsWith('.js') || a.endsWith('.mjs'))
);

// ---------------------------------------------------------------------------
// The gates. Each is a function (node) -> violation string | null.
// ---------------------------------------------------------------------------
const ENUM_FIELDS = [
  { type: 'Property',               field: 'kind',       legal: ['init', 'get', 'set'] },
  { type: 'MethodDefinition',       field: 'kind',       legal: ['constructor', 'method', 'get', 'set'] },
  { type: 'VariableDeclaration',    field: 'kind',       legal: ['var', 'let', 'const', 'using', 'await using'] },
  { type: 'Program',                field: 'sourceType', legal: ['script', 'module'] },
  { type: 'AssignmentExpression',   field: 'operator',   legal: ['=', '+=', '-=', '*=', '/=', '%=', '**=',
                                                                 '<<=', '>>=', '>>>=', '|=', '^=', '&=',
                                                                 '||=', '&&=', '??='] },
  { type: 'BinaryExpression',       field: 'operator',   legal: ['+', '-', '*', '/', '%', '**',
                                                                 '&', '|', '^', '<<', '>>', '>>>',
                                                                 '==', '!=', '===', '!==',
                                                                 '<', '<=', '>', '>=',
                                                                 'instanceof', 'in'] },
  { type: 'LogicalExpression',      field: 'operator',   legal: ['&&', '||', '??'] },
  { type: 'UpdateExpression',       field: 'operator',   legal: ['++', '--'] },
  { type: 'UnaryExpression',        field: 'operator',   legal: ['-', '+', '!', '~', 'typeof', 'void', 'delete'] },
];

// Shape discriminators: parent type + field -> legal set of child types.
// For fields that are arrays, we check every element.
const SHAPE_DISCRIMINATORS = [
  { parent: 'ObjectPattern',    field: 'properties', isArray: true,  legal: new Set(['Property', 'RestElement']) },
  { parent: 'ClassBody',        field: 'body',       isArray: true,  legal: new Set(['MethodDefinition', 'PropertyDefinition', 'StaticBlock', 'AccessorProperty']) },
  { parent: 'SwitchStatement',  field: 'cases',      isArray: true,  legal: new Set(['SwitchCase']) },
  { parent: 'ChainExpression',  field: 'expression', isArray: false, legal: new Set(['MemberExpression', 'CallExpression']) },
];

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

const counters = {};   // key -> { count, sample }
function record(key, detail) {
  const b = counters[key] || { count: 0, sample: null };
  b.count++;
  if (b.sample === null) b.sample = detail;
  counters[key] = b;
}

function visit(tree, file) {
  (function walk(node) {
    if (node == null) return;
    if (Array.isArray(node)) { for (const c of node) walk(c); return; }
    if (typeof node !== 'object') return;

    // Enum-field checks.
    for (const g of ENUM_FIELDS) {
      if (node.type === g.type && g.field in node) {
        const v = node[g.field];
        if (typeof v !== 'string' || !g.legal.includes(v)) {
          record(`${g.type}.${g.field} = <invalid>`,
            `${file}: ${g.type}.${g.field} = ${JSON.stringify(v)} (expected one of ${g.legal.join(', ')})`);
        }
      }
    }
    // Shape discriminator checks.
    for (const d of SHAPE_DISCRIMINATORS) {
      if (node.type === d.parent && d.field in node) {
        const v = node[d.field];
        if (d.isArray) {
          if (Array.isArray(v)) {
            for (let i = 0; i < v.length; i++) {
              const el = v[i];
              if (el && typeof el === 'object' && typeof el.type === 'string') {
                if (!d.legal.has(el.type)) {
                  record(`${d.parent}.${d.field}[].type = <invalid>`,
                    `${file}: ${d.parent}.${d.field}[${i}].type = ${JSON.stringify(el.type)} (expected one of ${[...d.legal].join(', ')})`);
                }
              }
            }
          }
        } else {
          if (v && typeof v === 'object' && typeof v.type === 'string') {
            if (!d.legal.has(v.type)) {
              record(`${d.parent}.${d.field}.type = <invalid>`,
                `${file}: ${d.parent}.${d.field}.type = ${JSON.stringify(v.type)} (expected one of ${[...d.legal].join(', ')})`);
            }
          }
        }
      }
    }

    for (const k of Object.keys(node)) walk(node[k]);
  })(tree);
}

(async () => {
const files = listFiles();
let parsed, parseFails;

const result = await parseCorpusParallel(files, {
  kesselBin: KESSEL,
  onFile: (tree, file) => visit(tree, path.relative(ROOT, file)),
});
parsed = result.parsed;
parseFails = result.parseFails;

const current = {};
for (const [k, v] of Object.entries(counters)) current[k] = v.count;

console.log(`Parsed: ${parsed}/${files.length} file(s), ${parseFails} failed`);
console.log('');

const baseline = fs.existsSync(BASELINE_PATH)
  ? JSON.parse(fs.readFileSync(BASELINE_PATH, 'utf8'))
  : null;

if (UPDATE || baseline === null) {
  fs.writeFileSync(BASELINE_PATH, JSON.stringify(current, null, 2) + '\n');
  console.log(`Baseline ${baseline === null ? 'created' : 'updated'}: ${BASELINE_PATH}`);
  for (const [k, b] of Object.entries(counters)) {
    console.log(`  ${b.count}x  ${k}`);
    if (b.sample) console.log(`        e.g. ${b.sample}`);
  }
  if (Object.keys(counters).length === 0) console.log('  (no violations)');
  process.exit(0);
}

// Single-file mode: zero-tolerance.
if (singleFile) {
  if (Object.keys(counters).length > 0) {
    console.log('FAIL (single-file mode, zero-tolerance):');
    for (const [k, b] of Object.entries(counters)) {
      console.log(`  ${b.count}x  ${k}`);
      if (b.sample) console.log(`        e.g. ${b.sample}`);
    }
    process.exit(1);
  }
  console.log('OK (single-file, zero violations)');
  process.exit(0);
}

// Corpus mode: compare to baseline.
let regressions = 0;
let improvements = 0;
const seen = new Set();
for (const [k, c] of Object.entries(current)) {
  seen.add(k);
  const prev = baseline[k];
  if (prev === undefined) {
    console.log(`  +${c}x  ${k} (NEW)`);
    regressions++;
  } else if (c > prev) {
    console.log(`  +${c - prev}  ${k}: ${prev} -> ${c} (regressed)`);
    regressions++;
  } else if (c < prev) {
    console.log(`  -${prev - c}  ${k}: ${prev} -> ${c} (improved)`);
    improvements++;
  } else {
    console.log(`       ${k}: ${c} (baseline)`);
  }
}
for (const [k, prev] of Object.entries(baseline)) {
  if (seen.has(k)) continue;
  console.log(`  -${prev}  ${k}: ${prev} -> 0 (improved, class gone)`);
  improvements++;
}

console.log('');
if (regressions > 0) {
  console.log(`REGRESSIONS in ${regressions} class(es).`);
  process.exit(1);
}
if (improvements > 0) console.log(`${improvements} class(es) improved. Run with --update to relock.`);
console.log('OK (corpus, no regressions)');
process.exit(0);
})();
