#!/usr/bin/env node
// Comment-survival measurement for the pretty printer.
//
// For every input that parses cleanly this script prints the file, reads the
// comments of the original and of the output with the pinned oxc-parser, and
// reports per syntactic position ("bucket") how many ordinary comments:
//
//   survived  the same comment text is present in the output,
//   anchored  the node that follows the comment is the same kind of node and
//             begins with the same text in both the original and the output.
//
// The bucket is the innermost node that contains the comment, refined for
// calls and functions. Legal notices, bundler annotations and source-map
// comments follow their own printer rules and are counted separately.
//
// Usage:
//   node tests/verifiers/measure_codegen_comments.js [options] <file|dir>...
//     --binary <path>   kessel binary (default bin/kessel)
//     --printer <name>  kessel (default) or oxc (needs --oxc-binary)
//     --oxc-binary <p>  program that prints one file with the Oxc printer
//     --every <n>       keep every n-th input after sorting (sampling)
//     --typescript      keep only .ts/.tsx inputs (default: all JS/TS inputs)
//     --check           also verify AST identity, second-print stability
//     --lost <n>        list the first n lost comments
//     --json <path>     write the totals as JSON
//
// This is a measurement, not a gate: it exits 0 unless --check finds an
// output that does not reparse to the same AST or is not stable.
'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

const ROOT = path.resolve(__dirname, '../..');
const { parseSync } = require(path.join(ROOT, 'bench/node_modules/oxc-parser'));

const options = {
  binary: path.join(ROOT, 'bin/kessel'), printer: 'kessel', oxcBinary: '',
  every: 1, typescript: false, check: false, lost: 0, json: '', inputs: [],
};
for (let i = 2; i < process.argv.length; i++) {
  const arg = process.argv[i];
  if (arg === '--binary') options.binary = path.resolve(process.argv[++i]);
  else if (arg === '--printer') options.printer = process.argv[++i];
  else if (arg === '--oxc-binary') options.oxcBinary = path.resolve(process.argv[++i]);
  else if (arg === '--every') options.every = parseInt(process.argv[++i], 10);
  else if (arg === '--typescript') options.typescript = true;
  else if (arg === '--check') options.check = true;
  else if (arg === '--lost') options.lost = parseInt(process.argv[++i], 10);
  else if (arg === '--json') options.json = process.argv[++i];
  else options.inputs.push(path.resolve(arg));
}
if (options.inputs.length === 0 || !(options.every >= 1)) {
  console.error('usage: measure_codegen_comments.js [options] <file|dir>...');
  process.exit(2);
}

function walk(entry, out) {
  const stat = fs.statSync(entry);
  if (stat.isFile()) { out.push(entry); return; }
  for (const name of fs.readdirSync(entry).sort()) {
    if (name === 'node_modules' || name === '.git') continue;
    const full = path.join(entry, name);
    if (fs.statSync(full).isDirectory()) walk(full, out);
    else if (/\.(js|mjs|cjs|jsx|ts|tsx)$/.test(name) && !/\.d\.ts$/.test(name)) out.push(full);
  }
}

function print(file) {
  if (options.printer === 'oxc') {
    return execFileSync(options.oxcBinary, [file], {
      encoding: 'utf8', maxBuffer: 1 << 30, stdio: ['ignore', 'pipe', 'ignore'],
    });
  }
  return execFileSync(options.binary, ['codegen', file], {
    encoding: 'utf8', maxBuffer: 1 << 30, stdio: ['ignore', 'pipe', 'ignore'],
  });
}

function kesselAst(file) {
  const out = execFileSync(options.binary, ['parse', file, '--json', '--compact'], {
    encoding: 'utf8', maxBuffer: 1 << 30, stdio: ['ignore', 'pipe', 'ignore'],
  });
  const drop = new Set(['start', 'end', 'range', 'loc', 'raw', 'comments']);
  return JSON.stringify(JSON.parse(out), (key, value) => (drop.has(key) ? undefined : value));
}

// Flat, start-sorted node table. Parents precede their children.
function collectNodes(program) {
  const nodes = [];
  const pending = [[program, -1]];
  while (pending.length) {
    const [value, parent] = pending.pop();
    if (value === null || typeof value !== 'object') continue;
    if (Array.isArray(value)) {
      for (let i = value.length - 1; i >= 0; i--) pending.push([value[i], parent]);
      continue;
    }
    let self = parent;
    if (typeof value.type === 'string' && typeof value.start === 'number') {
      self = nodes.length;
      nodes.push({ type: value.type, start: value.start, end: value.end, parent, node: value });
    }
    const keys = Object.keys(value);
    for (let i = keys.length - 1; i >= 0; i--) {
      if (keys[i] !== 'type') pending.push([value[keys[i]], self]);
    }
  }
  return nodes;
}

function commentKind(comment) {
  const text = comment.value.trim();
  if (/^[#@]__(PURE|NO_SIDE_EFFECTS)__$/.test(text)) return 'annotation';
  if (/^[#@]\s*sourceMappingURL/.test(text)) return 'source-map';
  if (comment.value.startsWith('!') || /@license|@preserve/.test(comment.value)) return 'legal';
  return 'ordinary';
}

// The printer respells annotations in their canonical form. A printer may
// also reindent the continuation lines of a block comment; that is the same
// comment, so lines are compared without their surrounding blanks.
function commentKey(comment) {
  if (commentKind(comment) === 'annotation') return 'annotation' + comment.value.trim().replace('@', '#');
  return comment.type + comment.value.split('\n').map(line => line.trim()).join('\n');
}

const STATEMENT_LISTS = new Set(['Program', 'BlockStatement', 'StaticBlock', 'TSModuleBlock']);
const FUNCTIONS = new Set([
  'FunctionDeclaration', 'FunctionExpression', 'ArrowFunctionExpression',
  'TSDeclareFunction', 'TSEmptyBodyFunctionExpression',
]);

function bucketOf(container, comment) {
  const { type, node } = container;
  if (STATEMENT_LISTS.has(type)) return 'statement list';
  if (type === 'ClassBody') return 'class members';
  if (type === 'ObjectExpression') return 'object properties';
  if (type === 'ArrayExpression') return 'array elements';
  if (type === 'CallExpression' || type === 'NewExpression' || type === 'ImportExpression') {
    if (type === 'ImportExpression') return 'call arguments';
    return node.callee && comment.start >= node.callee.end ? 'call arguments' : 'call callee';
  }
  if (FUNCTIONS.has(type)) {
    if (node.body && comment.start >= node.body.end) return 'function tail';
    const params = node.params || [];
    const last = params.length ? params[params.length - 1].end : -1;
    if (type === 'ArrowFunctionExpression' && comment.start >= last && params.length) return 'arrow body';
    return 'function parameters';
  }
  if (type === 'BinaryExpression' || type === 'LogicalExpression') return 'binary operands';
  if (type === 'MemberExpression' || type === 'ChainExpression') return 'member chain';
  if (type === 'ConditionalExpression') return 'conditional branches';
  if (type === 'SwitchStatement' || type === 'SwitchCase') return 'switch cases';
  if (type === 'TSInterfaceBody' || type === 'TSTypeLiteral') return 'interface/type members';
  if (type === 'TSEnumBody' || type === 'TSEnumDeclaration') return 'enum members';
  if (type.startsWith('JSX')) return 'JSX';
  if (/^(Import|Export)/.test(type)) return 'import/export';
  if (type.startsWith('TS')) return 'type annotations (' + type + ')';
  return type;
}

// The node a reader associates with a leading comment: the outermost node
// that starts at the first node boundary after the comment.
function anchorOf(nodes, starts, source, comment) {
  let low = 0, high = starts.length;
  while (low < high) {
    const middle = (low + high) >> 1;
    if (nodes[starts[middle]].start < comment.end) low = middle + 1; else high = middle;
  }
  if (low === starts.length) return 'end of file';
  const next = nodes[starts[low]];
  // Printing may drop grouping parentheses and respell quotes and spacing.
  const head = source.slice(next.start, next.start + 40).replace(/[\s();]+/g, '').replace(/['`]/g, '"');
  return next.type + ':' + head.slice(0, 10);
}

function analyse(file, source) {
  const parsed = parseSync(file, source);
  if (parsed.errors.length) return null;
  const nodes = collectNodes(parsed.program);
  // Outermost first among nodes that share a start: longer span sorts first.
  const starts = nodes.map((_, i) => i).sort((a, b) =>
    nodes[a].start - nodes[b].start || nodes[b].end - nodes[a].end);
  const comments = parsed.comments.slice().sort((a, b) => a.start - b.start);
  return { nodes, starts, comments, source };
}

function containerOf(nodes, starts, comment) {
  // Innermost node whose span contains the comment: scan candidates that
  // start before the comment, walking up through parents from the nearest.
  let low = 0, high = starts.length;
  while (low < high) {
    const middle = (low + high) >> 1;
    if (nodes[starts[middle]].start <= comment.start) low = middle + 1; else high = middle;
  }
  let index = low > 0 ? starts[low - 1] : -1;
  while (index >= 0 && nodes[index].end < comment.end) index = nodes[index].parent;
  return index >= 0 ? nodes[index] : { type: 'Program', node: {} };
}

const totals = new Map();
const kinds = { legal: [0, 0], annotation: [0, 0], 'source-map': [0, 0] };
const lostExamples = [];
let files = 0, skipped = 0, broken = 0, unstable = 0, astDrift = 0, extra = 0;

function tally(bucket, survived, anchored, jsdoc) {
  if (!totals.has(bucket)) totals.set(bucket, { total: 0, survived: 0, anchored: 0, jsdoc: 0, jsdocSurvived: 0 });
  const row = totals.get(bucket);
  row.total += 1;
  if (survived) row.survived += 1;
  if (anchored) row.anchored += 1;
  if (jsdoc) { row.jsdoc += 1; if (survived) row.jsdocSurvived += 1; }
}

function measure(file, scratch) {
  const source = fs.readFileSync(file, 'utf8');
  let original;
  try { original = analyse(file, source); } catch { original = null; }
  if (!original) { skipped += 1; return; }
  let output;
  try { output = print(file); } catch { skipped += 1; return; }
  const regenerated = path.join(scratch, 'out' + path.extname(file));
  fs.writeFileSync(regenerated, output);
  let printed;
  try { printed = analyse(regenerated, output); } catch { printed = null; }
  files += 1;
  if (!printed) { broken += 1; console.error('output does not reparse: ' + file); }
  if (options.check && printed && options.printer === 'kessel') {
    // A printer that rejects its own output counts as both failures.
    let again = null, same = false;
    try { again = print(regenerated); } catch { again = null; }
    try { same = kesselAst(file) === kesselAst(regenerated); } catch { same = false; }
    if (again !== output) { unstable += 1; console.error('second print differs: ' + file); }
    if (!same) { astDrift += 1; console.error('AST differs: ' + file); }
  }
  // Pair equal comment texts in source order.
  const available = new Map();
  for (const comment of printed ? printed.comments : []) {
    const key = commentKey(comment);
    if (!available.has(key)) available.set(key, []);
    available.get(key).push(comment);
  }
  let matched = 0;
  for (const comment of original.comments) {
    const kind = commentKind(comment);
    const queue = available.get(commentKey(comment));
    const twin = queue && queue.length ? queue.shift() : null;
    if (twin) matched += 1;
    if (kind !== 'ordinary') {
      kinds[kind][0] += 1;
      if (twin) kinds[kind][1] += 1;
      continue;
    }
    const container = containerOf(original.nodes, original.starts, comment);
    const bucket = bucketOf(container, comment);
    let anchored = false;
    if (twin) {
      anchored = anchorOf(original.nodes, original.starts, source, comment) ===
        anchorOf(printed.nodes, printed.starts, output, twin);
    } else if (lostExamples.length < options.lost) {
      lostExamples.push(`${path.relative(ROOT, file)}:${comment.start} [${bucket}] ` +
        JSON.stringify(source.slice(Math.max(0, comment.start - 30), comment.end + 30)));
    }
    tally(bucket, Boolean(twin), anchored, comment.type === 'Block' && comment.value.startsWith('*'));
  }
  if (printed) extra += printed.comments.length - matched;
}

const inputs = [];
for (const input of options.inputs) walk(input, inputs);
inputs.sort();
const selected = inputs.filter((file, index) =>
  index % options.every === 0 && (!options.typescript || /\.tsx?$/.test(file)));
const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'kessel-comment-measure-'));
try {
  for (const file of selected) measure(file, scratch);
} finally {
  fs.rmSync(scratch, { recursive: true, force: true });
}

const rows = [...totals.entries()].sort((a, b) =>
  (b[1].total - b[1].survived) - (a[1].total - a[1].survived) || b[1].total - a[1].total);
const sum = { total: 0, survived: 0, anchored: 0, jsdoc: 0, jsdocSurvived: 0 };
const percent = (part, whole) => (whole ? (100 * part / whole).toFixed(2) + '%' : '-');
console.log(`printer=${options.printer} files=${files} skipped=${skipped} ` +
  `output_reparse_failures=${broken} extra_output_comments=${extra}` +
  (options.check ? ` unstable=${unstable} ast_drift=${astDrift}` : ''));
console.log(['bucket', 'total', 'survived', 'lost', 'rate', 'anchored', 'anchored rate'].join('\t'));
for (const [bucket, row] of rows) {
  for (const key of Object.keys(sum)) sum[key] += row[key];
  console.log([bucket, row.total, row.survived, row.total - row.survived,
    percent(row.survived, row.total), row.anchored, percent(row.anchored, row.total)].join('\t'));
}
console.log(['ALL ORDINARY', sum.total, sum.survived, sum.total - sum.survived,
  percent(sum.survived, sum.total), sum.anchored, percent(sum.anchored, sum.total)].join('\t'));
console.log(`JSDoc blocks: ${sum.jsdocSurvived}/${sum.jsdoc} survived (${percent(sum.jsdocSurvived, sum.jsdoc)})`);
for (const [kind, [total, survived]] of Object.entries(kinds)) {
  console.log(`${kind}: ${survived}/${total} survived`);
}
for (const example of lostExamples) console.log('lost: ' + example);
if (options.json) {
  fs.writeFileSync(options.json, JSON.stringify({
    files, skipped, broken, unstable, astDrift, extra, sum, kinds, buckets: Object.fromEntries(totals),
  }, null, 2));
}
process.exit(options.check && (broken || unstable || astDrift) ? 1 : 0);
