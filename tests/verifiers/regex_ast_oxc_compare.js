'use strict';

// oxc side of verify_regex_ast_reference.js: builds and runs the reference
// dump tool, brings oxc's tree to Kessel's conventions, and compares.
//
// The comparison is exact. Where the two parsers differ on purpose the
// difference is handled in one of three ways, each recorded here with the
// evidence that Kessel's answer is the right one:
//
//   alignOxcTree     representation choices (no observable behaviour)
//   repairOxcTree    oxc parsing bugs with a local, mechanical correction;
//                    after the repair the trees must match exactly
//   treeDeviations   oxc parsing bugs with no local correction; listed per
//                    pattern, and a listed pattern that stops differing fails
//   deviationRules   two such bugs that any corpus can trigger, including the
//                    generated one, so they are matched by spelling instead
//
// Accept/reject differences need no list: Node arbitrates. When oxc and Kessel
// disagree on whether a pattern is valid and Node sides with Kessel, the
// pattern is reported and counted under "oxc differs from Node"; when Node
// sides with oxc the Node gate has already failed.

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

// Evidence for repairOxcTree and treeDeviations, run against Node on every
// invocation so the claims cannot rot.
function proveOxcDeviations() {
  const matches = (pattern, flags, input) => new RegExp(pattern, flags).test(input);
  // Control escapes in a class. oxc reads `[\cA]` as the three characters `\`,
  // `c`, `A`. ECMA-262 CharacterEscape `c AsciiLetter` applies in classes too,
  // and Annex B ClassControlLetter adds digits and `_` without `u`/`v`.
  assert.ok(matches('[\\cA]', '', '\x01') && !matches('[\\cA]', '', 'c'));
  assert.ok(matches('[\\cA]', 'u', '\x01') && !matches('[\\cA]', 'u', 'A'));
  assert.ok(matches('[\\c0]', '', '\x10') && !matches('[\\c0]', '', '0'));
  assert.ok(matches('[\\c_]', '', '\x1f') && !matches('[\\c_]', '', '_'));
  assert.ok(matches('^[\\c0-\\c9]+$', '', '\x10\x15\x19') && !matches('[\\c0-\\c9]', '', '5'));
  // Legacy octal escapes. oxc gives `\400` the value of `\40` but a span that
  // swallows the third digit, so the `0` is lost. Annex B
  // LegacyOctalEscapeSequence takes a third digit only after 0-3: `\400` is
  // `\40` (a space) followed by the character `0`.
  assert.ok(matches('^\\400$', '', ' 0') && !matches('\\400', '', 'Ā'));
  assert.ok(matches('^[\\777]+$', '', '?7') && !matches('[\\777]', '', 'ǿ'));
  // `\01` is the octal escape U+0001 even when a group exists. oxc reads it
  // as a backreference to group 1; DecimalEscape cannot start with 0.
  assert.ok(matches('^(a)\\01$', '', 'a\x01') && !matches('^(a)\\01$', '', 'aa'));
  // A modifier group captures nothing. oxc counts `(?i:` as a capturing group
  // when it decides whether `\1` is a backreference; with no group to refer
  // to, Annex B makes `\1` the octal escape U+0001.
  assert.ok(matches('^(?i:a)\\1$', '', 'a\x01') && !matches('^(?i:a)\\1$', '', 'aa'));
}

const key = (pattern, flags) => JSON.stringify([pattern, flags]);

// Patterns whose oxc tree is wrong in a way repairOxcTree cannot mend.
const treeDeviations = new Map([
  [key('(a)\\01', ''), 'oxc reads \\01 as a backreference; it is the octal escape U+0001'],
  [key('[\\c0-\\c9]', ''),
    'oxc reads \\c0 in a class as three characters, which also moves the range'],
]);

// Spellings that trigger an oxc bug wherever they occur. A pattern that
// matches a rule is still compared and counts as a deviation only if it does
// differ. Both bugs are proven in proveOxcDeviations.
const deviationRules = [
  {
    reason: 'oxc counts a modifier group as a capture, so a later \\1 becomes a reference',
    applies: result => !/[uv]/.test(result.flags) && /\(\?[ims-]+:/.test(result.pattern) &&
      /\\[1-9]/.test(result.pattern),
  },
  {
    reason: 'oxc reads \\400 as one character; under a quantifier or in a range the ' +
      'repair in repairOxcTree cannot split it',
    applies: result => !/[uv]/.test(result.flags) && /\\[4-7][0-7][0-7]/.test(result.pattern),
  },
];

function buildOxcTool(checkout) {
  const crate = path.join(checkout, 'crates/oxc_regular_expression');
  if (!fs.existsSync(path.join(crate, 'Cargo.toml'))) return null;
  const work = process.env.KESSEL_REGEXP_REFERENCE_DIR ||
    path.join(os.tmpdir(), 'kessel-regexp-oxc-reference');
  fs.mkdirSync(path.join(work, 'crate/src'), { recursive: true });
  // The manifest is generated because a path dependency cannot come from the
  // environment; the empty [workspace] keeps cargo out of the oxc workspace.
  // LTO stays off: the tool runs once per gate and should build quickly.
  const manifest = [
    '[package]', 'name = "kessel_regex_oxc_reference"', 'version = "0.0.0"',
    'edition = "2024"', 'publish = false', '', '[workspace]', '', '[dependencies]',
    `oxc_allocator = { path = ${JSON.stringify(path.join(checkout, 'crates/oxc_allocator'))} }`,
    `oxc_regular_expression = { path = ${JSON.stringify(crate)} }`,
    'serde_json = "1"', '', '[profile.release]', 'opt-level = 2', 'lto = false',
    'codegen-units = 16', 'debug = false', '',
  ].join('\n');
  const manifestPath = path.join(work, 'crate/Cargo.toml');
  // Rewriting an identical manifest would make cargo rebuild for nothing.
  const current = fs.existsSync(manifestPath) ? fs.readFileSync(manifestPath, 'utf8') : null;
  if (current !== manifest) fs.writeFileSync(manifestPath, manifest);
  fs.copyFileSync(path.join(__dirname, 'regex_ast_oxc_reference.rs'),
    path.join(work, 'crate/src/main.rs'));
  const target = path.join(work, 'target');
  const build = spawnSync('cargo', ['build', '--release', '--quiet'], {
    cwd: path.join(work, 'crate'), encoding: 'utf8',
    env: { ...process.env, CARGO_TARGET_DIR: target },
  });
  assert.equal(build.status, 0, `cargo build failed:\n${build.stderr || build.error}`);
  return path.join(target, 'release/kessel_regex_oxc_reference');
}

function runOxc(tool, results) {
  const input = results.map(result => JSON.stringify({ p: result.pattern, f: result.flags }));
  const run = spawnSync(tool, [], {
    input: input.join('\n') + '\n', encoding: 'utf8', maxBuffer: 1 << 30,
  });
  assert.equal(run.status, 0, `oxc reference tool failed: ${run.stderr || run.error}`);
  const lines = run.stdout.split('\n').filter(line => line !== '');
  assert.equal(lines.length, results.length, 'oxc reference tool must answer every pattern');
  return lines.map(line => JSON.parse(line));
}

// Representation choices, applied to oxc's side before comparing.
//
// 1. oxc rewrites a lone general category value such as `\p{Lu}` to name
//    "General_Category", value "Lu". Kessel's tree is source-preserving and
//    reports name "Lu" with no value, matching the spec production
//    LoneUnicodePropertyNameOrValue, which does not say which of the two it is.
// 2. Without `u`/`v` an astral source character is two pattern characters (the
//    UTF-16 code units). oxc gives the trail unit an empty span at the end of
//    the character, which its own ast.rs calls an invalid position. Kessel
//    gives both units the span of the source character, so every span still
//    selects real source text. A quantifier or range that starts with the
//    trail unit starts where that character starts.
function alignOxcTree(node, bytes) {
  if (node.k === 'UnicodePropertyEscape' && node.name === 'General_Category' &&
      !bytes.subarray(node.s, node.e).includes('=')) {
    return { ...node, name: node.value, value: null };
  }
  const trail = node.k === 'Character' && node.s === node.e &&
    node.value >= 0xdc00 && node.value <= 0xdfff;
  if (trail) return { ...node, s: node.e - 4 };
  if (!node.c) return node;
  const aligned = { ...node, c: node.c.map(child => alignOxcTree(child, bytes)) };
  const first = aligned.c[0];
  const leads = node.k === 'Quantifier' || node.k === 'CharacterClassRange';
  if (leads && first.k === 'Character' && first.s < aligned.s) aligned.s = first.s;
  return aligned;
}

// `\`, `c`, X as three class members where the source spells one control
// escape `\cX`. Returns the merged member, or null.
function mergedControlEscape(members, index, bytes, unicode) {
  const [slash, letter, value] = members.slice(index, index + 3);
  if (!value || slash.k !== 'Character' || letter.k !== 'Character' || value.k !== 'Character') {
    return null;
  }
  const adjacent = slash.e === letter.s && letter.e === value.s && value.e === value.s + 1;
  const spelled = bytes.subarray(slash.s, value.e).toString('latin1');
  const allowed = unicode ? /^\\c[A-Za-z]$/ : /^\\c[A-Za-z0-9_]$/;
  if (!adjacent || !allowed.test(spelled)) return null;
  const control = value.value & 0x1f;
  return { k: 'Character', s: slash.s, e: value.e, kind: 'ControlLetter', value: control };
}

// A three digit octal escape above 0o377, which the grammar reads as a two
// digit escape and a digit. Returns the two members, or null.
function splitOctalEscape(node, bytes) {
  if (node.k !== 'Character' || node.kind !== 'Octal3') return null;
  const spelled = bytes.subarray(node.s, node.e).toString('latin1');
  if (!/^\\[4-7][0-7][0-7]$/.test(spelled)) return null;
  const last = node.e - 1;
  return [
    { k: 'Character', s: node.s, e: last, kind: 'Octal2', value: node.value },
    { k: 'Character', s: last, e: node.e, kind: 'Symbol', value: bytes[last] },
  ];
}

// Mechanical corrections of two oxc bugs; see proveOxcDeviations for the
// evidence. Only plain member lists are repaired. A wrong member that oxc has
// also folded into a range or a quantifier is left alone and must be listed in
// treeDeviations.
function repairOxcTree(node, bytes, unicode) {
  if (!node.c) return node;
  const children = node.c.map(child => repairOxcTree(child, bytes, unicode));
  const repaired = [];
  for (let index = 0; index < children.length; index += 1) {
    const merged = node.k === 'CharacterClass' ?
      mergedControlEscape(children, index, bytes, unicode) : null;
    const split = node.k === 'CharacterClass' || node.k === 'Alternative' ?
      splitOctalEscape(children[index], bytes) : null;
    if (merged) {
      repaired.push(merged);
      index += 2;
    } else if (split) {
      repaired.push(...split);
    } else {
      repaired.push(children[index]);
    }
  }
  return { ...node, c: repaired };
}

function firstDifference(left, right, trail) {
  if (left === right) return null;
  const plain = value => value === null || typeof value !== 'object';
  if (plain(left) || plain(right)) {
    return `${trail}: kessel ${JSON.stringify(left)} oxc ${JSON.stringify(right)}`;
  }
  const keys = new Set([...Object.keys(left), ...Object.keys(right)]);
  // Report scalar fields before descending, so the message names the node.
  const ordered = [...keys].sort((a, b) => (a === 'c') - (b === 'c') || (a < b ? -1 : 1));
  for (const name of ordered) {
    const label = Array.isArray(left) ? `${trail}[${name}]` : `${trail}.${left.k || ''}.${name}`;
    const found = firstDifference(left[name], right[name], label);
    if (found) return found;
  }
  return null;
}

function compareTrees(result, oxc) {
  if (result.malformed) return `malformed tree: ${result.malformed}`;
  const bytes = Buffer.from(result.pattern);
  const unicode = /[uv]/.test(result.flags);
  const expected = repairOxcTree(alignOxcTree(oxc, bytes), bytes, unicode);
  return firstDifference(result.tree, expected, '');
}

// Compare one corpus. `results` come from the Node gate and carry Kessel's
// normalized tree; `oxcTrees` are the tool's answers in the same order.
function checkOxcAgreement(name, results, oxcTrees, failures, seenDeviations, notes) {
  const counts = {
    same: 0, bothReject: 0, treeDiffers: 0, listed: 0, oxcDiffersFromNode: 0, skipped: 0,
  };
  const show = result => `/${result.pattern}/${result.flags}`;
  results.forEach((result, index) => {
    const oxc = oxcTrees[index];
    if (result.pattern === '') {
      // oxc substitutes `(?:)` for an empty literal body; there is no tree to compare.
      counts.skipped += 1;
      return;
    }
    const oxcAccepts = oxc.err === undefined;
    const listed = treeDeviations.has(result.key);
    const ruled = deviationRules.some(rule => rule.applies(result));
    if (oxcAccepts !== result.kessel) {
      const word = accepts => (accepts ? 'accepts' : 'rejects');
      const verdicts = `oxc ${word(oxcAccepts)}${oxcAccepts ? '' : ' (' + oxc.err + ')'}, ` +
        `Kessel ${word(result.kessel)}, Node ${word(result.node)}`;
      if (result.node === result.kessel) {
        counts.oxcDiffersFromNode += 1;
        notes.push(`${name}: ${show(result)} ${verdicts}`);
      } else {
        failures.push(`${name}: ${show(result)} ${verdicts}`);
      }
      if (listed) {
        failures.push(`${name}: tree deviation listed for a verdict difference: ${show(result)}`);
      }
      return;
    }
    const problem = oxcAccepts ? compareTrees(result, oxc) : null;
    if (problem === null) {
      if (listed) failures.push(`${name}: listed oxc deviation no longer occurs: ${show(result)}`);
      counts[oxcAccepts ? 'same' : 'bothReject'] += 1;
    } else if (listed || ruled) {
      seenDeviations.add(result.key);
      counts.listed += 1;
    } else {
      counts.treeDiffers += 1;
      failures.push(`${name}: ${show(result)} ${problem}`);
    }
  });
  return counts;
}

// Pattern lists oxc's own tests and examples use, as extra inputs.
function loadOxcPatternLists(checkout) {
  const crate = path.join(checkout, 'crates/oxc_regular_expression');
  const literals = [];
  for (const file of ['src/parser/mod.rs', 'examples/parse_literal.rs', 'tests/diagnostics.rs']) {
    const source = fs.readFileSync(path.join(crate, file), 'utf8');
    // Tuples of the form (r"pattern", "flags") or ("pattern", "flags", ...).
    const tuple = /\(\s*(r?)"((?:[^"\\]|\\.)*)",\s*"([a-zA-Z]*)"/g;
    for (let match = tuple.exec(source); match !== null; match = tuple.exec(source)) {
      const pattern = match[1] === 'r' ? match[2] : JSON.parse(`"${match[2]}"`);
      literals.push({ pattern, flags: match[3], origin: 'constructor' });
    }
  }
  assert.ok(literals.length > 100, 'oxc pattern lists moved; update loadOxcPatternLists');
  return literals;
}

module.exports = {
  buildOxcTool, checkOxcAgreement, loadOxcPatternLists, proveOxcDeviations, runOxc,
  treeDeviations,
};
