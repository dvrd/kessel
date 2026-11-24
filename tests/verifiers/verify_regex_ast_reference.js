'use strict';

// Reference gate for the regexp tree builder (`kessel regexp`, parseRegExpSync).
//
// Goal: every regexp literal in test262 and in the real-world benchmark corpus,
// plus the grammar-area and property-name lists in
// regex_ast_reference_patterns.js, must be handled the way two independent
// implementations handle it.
//
//   1. Accept/reject versus Node. `new RegExp(pattern, flags)` is the oracle:
//      Kessel must build a tree exactly when Node compiles the pattern. This
//      part always runs.
//   2. Tree structure versus oxc. The oxc regular expression parser dumps a
//      normalized tree through regex_ast_oxc_reference.rs; Kessel's flat node
//      array is converted to the same shape (regex_ast_normalize.js) and
//      compared node for node: kind, byte span, children, capture names,
//      quantifier bounds, class contents, code points. This part needs an oxc
//      checkout and a Rust toolchain, so it runs only with `--oxc <checkout>`
//      and is skipped with a loud message otherwise. To keep tree drift visible
//      without oxc, the always-on part compares a digest of Kessel's normalized
//      trees with regex_ast_reference.snap.json, which `--oxc <dir> --update`
//      writes only after the oxc comparison has passed.
//
// Methodology notes:
//   * Literals are found by a real tokenizer (regex_literal_corpus.js), so a
//     `/` is a regexp only where the language says so.
//   * A literal body is checked with the constructor. That is sound because a
//     body cannot hold what the constructor treats differently (an unescaped
//     `/` outside a class, a line terminator); the gate also compiles each
//     literal as real source and fails if Node's two entry points disagree.
//   * Patterns built from strings do contain those forms and go straight to
//     the constructor, which is also what parseRegExpSync models.
//   * Strings with lone surrogates are skipped and counted: the SDK takes UTF-8.
//
// Usage:
//   node verify_regex_ast_reference.js                        Node gate + digests
//   node verify_regex_ast_reference.js --oxc <dir>            also compare with oxc
//   node verify_regex_ast_reference.js --oxc <dir> --update   rewrite the snapshot
//   node verify_regex_ast_reference.js --dump <file>          write per-pair results

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const { extractCorpus } = require('./regex_literal_corpus');
const patterns = require('./regex_ast_reference_patterns');
const { normalizeKesselTree } = require('./regex_ast_normalize');
const oxcCompare = require('./regex_ast_oxc_compare');

const repository = path.resolve(__dirname, '../..');
const snapshotPath = path.join(__dirname, 'regex_ast_reference.snap.json');
const { parseRegExpSync } = require(path.join(repository, 'npm/kessel'));

function parseArguments(argv) {
  const options = { oxc: null, update: false, dump: null };
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === '--update') {
      options.update = true;
    } else if (argument === '--oxc' || argument === '--dump') {
      index += 1;
      assert.ok(index < argv.length, `${argument} needs a value`);
      options[argument.slice(2)] = argv[index];
    } else {
      assert.fail(`Unknown argument ${argument}`);
    }
  }
  assert.ok(!options.update || options.oxc,
    '--update needs --oxc: the snapshot records oxc-verified trees');
  return options;
}

// The oracle must itself implement ES2025, or every modifier and duplicate
// group name would be reported as a Kessel bug.
function checkOracle() {
  for (const [pattern, flags, feature] of [
    ['(?i:a)', '', 'regexp modifiers'], ['(?<a>x)|(?<a>y)', '', 'duplicate named groups'],
    ['[\\q{ab}--a]', 'v', 'the v flag'], ['(?<=a)b', '', 'lookbehind'],
  ]) {
    try {
      new RegExp(pattern, flags);
    } catch (_) {
      assert.fail(`Node ${process.version} lacks ${feature}; this gate needs Node 24 or newer`);
    }
  }
}

function pairKey(pattern, flags) {
  return JSON.stringify([pattern, flags]);
}

// Deduplicate occurrences into unique (pattern, flags) pairs, remembering
// whether a pair was ever seen as a source literal.
function uniquePairs(literals) {
  const pairs = new Map();
  for (const literal of literals) {
    const key = pairKey(literal.pattern, literal.flags);
    const known = pairs.get(key);
    if (known) {
      known.literal = known.literal || literal.origin === 'literal';
    } else {
      pairs.set(key, {
        key, pattern: literal.pattern, flags: literal.flags,
        literal: literal.origin === 'literal',
      });
    }
  }
  return [...pairs.values()];
}

function nodeAccepts(pattern, flags) {
  try {
    new RegExp(pattern, flags);
    return true;
  } catch (error) {
    assert.ok(error instanceof SyntaxError, `Node threw ${error} for ${pairKey(pattern, flags)}`);
    return false;
  }
}

// Compile the literal as source text. The empty body is skipped: `//` is a
// comment, not a literal.
function nodeLiteralAccepts(pattern, flags) {
  try {
    new vm.Script(`/${pattern}/${flags}`);
    return true;
  } catch (error) {
    assert.ok(error instanceof SyntaxError, `Node threw ${error} for /${pattern}/${flags}`);
    return false;
  }
}

function kesselParse(pattern, flags) {
  try {
    return { tree: parseRegExpSync(pattern, flags) };
  } catch (error) {
    const diagnostic = error instanceof SyntaxError &&
      (error.code === 'Invalid_Pattern' || error.code === 'Invalid_Flags');
    // Anything else (depth limit, allocation, a crash surfaced as an Error) is
    // neither a tree nor a syntax diagnostic and must fail the gate.
    assert.ok(diagnostic, `Kessel failed without a diagnostic for ${pairKey(pattern, flags)}: ` +
      `${error.code} ${error.message}`);
    assert.equal(typeof error.offset, 'number', 'diagnostics carry a byte offset');
    return { error: `${error.code}@${error.offset}: ${error.message}` };
  }
}

function evaluatePair(pair) {
  const kessel = kesselParse(pair.pattern, pair.flags);
  const node = nodeAccepts(pair.pattern, pair.flags);
  const result = { ...pair, node, kessel: kessel.tree !== undefined, error: kessel.error };
  if (kessel.tree) {
    // A tree the normalizer cannot walk (broken links, spans outside the
    // pattern, wrong capture numbering) is a failure of its own kind.
    try {
      result.tree = normalizeKesselTree(kessel.tree, pair.pattern);
    } catch (error) {
      if (!(error instanceof assert.AssertionError)) throw error;
      result.malformed = error.message.split('\n')[0];
    }
  }
  if (pair.literal && pair.pattern !== '') {
    result.nodeLiteral = nodeLiteralAccepts(pair.pattern, pair.flags);
  }
  return result;
}

function show(result) {
  return `/${result.pattern}/${result.flags}`;
}

// Node may know fewer Unicode properties than Kessel's tables, which follow
// TABLE_UNICODE_VERSION. A property escape that only an older Node rejects is
// reported, not failed.
function olderUnicodeOracle(result) {
  const [major, minor] = process.versions.unicode.split('.').map(Number);
  const [tableMajor, tableMinor] = patterns.TABLE_UNICODE_VERSION.split('.').map(Number);
  const older = major < tableMajor || (major === tableMajor && minor < tableMinor);
  return older && result.kessel && !result.node && /\\[pP]\{/.test(result.pattern);
}

// Compare Kessel with Node. A deviation is allowed only when listed with a
// reason in regex_ast_reference_patterns.js, and a listed deviation that no
// longer occurs is an error too, so the list cannot go stale.
function checkNodeAgreement(name, results, state) {
  const counts = { agree: 0, disagree: 0, listed: 0, olderOracle: 0 };
  for (const result of results) {
    if (result.malformed) {
      state.failures.push(`${name}: malformed tree for ${show(result)}: ${result.malformed}`);
    }
    if (result.nodeLiteral !== undefined && result.nodeLiteral !== result.node) {
      state.failures.push(`${name}: Node literal and constructor disagree on ${show(result)}`);
    }
    const listed = patterns.nodeDeviations.has(result.key);
    if (result.node === result.kessel) {
      counts.agree += 1;
      if (listed) {
        state.failures.push(`${name}: listed Node deviation no longer occurs: ${show(result)}`);
      }
    } else if (listed) {
      state.seenNodeDeviations.add(result.key);
      counts.listed += 1;
    } else if (olderUnicodeOracle(result)) {
      counts.olderOracle += 1;
    } else {
      counts.disagree += 1;
      state.failures.push(`${name}: ${show(result)} Node ${result.node ? 'accepts' : 'rejects'}, ` +
        `Kessel ${result.kessel ? 'accepts' : 'rejects (' + result.error + ')'}`);
    }
  }
  return counts;
}

function digest(lines) {
  const hash = crypto.createHash('sha256');
  for (const line of lines) hash.update(line).update('\n');
  return hash.digest('hex');
}

// Two digests per corpus: the inputs, so corpus drift is told apart from tree
// drift, and Kessel's normalized trees (or `reject`) in input order.
function corpusDigests(results) {
  const sorted = [...results].sort((a, b) => (a.key < b.key ? -1 : a.key > b.key ? 1 : 0));
  return {
    pairs: sorted.length,
    accepted: sorted.filter(result => result.kessel).length,
    inputs: digest(sorted.map(result => result.key)),
    trees: digest(sorted.map(result => (result.tree ? JSON.stringify(result.tree) : 'reject'))),
  };
}

function checkSnapshot(name, digests, snapshot, failures) {
  const expected = snapshot[name];
  if (!expected) {
    failures.push(`${name}: no snapshot entry; run with --oxc <checkout> --update`);
  } else if (expected.inputs !== digests.inputs) {
    // Corpus drift is not a tree regression, but the oxc-verified digest no
    // longer covers these inputs. Fail loudly instead of silently passing.
    failures.push(`${name}: corpus changed (${expected.pairs} -> ${digests.pairs} pairs); ` +
      'rerun with --oxc <checkout> --update to re-verify trees against oxc');
  } else if (expected.trees !== digests.trees) {
    failures.push(`${name}: Kessel trees differ from the oxc-verified snapshot; ` +
      'run with --oxc <checkout> to see which patterns changed');
  }
}

function collectCorpora(oxcCheckout) {
  const corpora = [];
  const describe = stats => `${stats.files} files: ${stats.parsedFiles} parsed, ` +
    `${stats.tokenizedFiles} token-only, ${stats.partialFiles} token-only stopped at a ` +
    `lexical error; ${stats.loneSurrogateStrings} constructor strings with lone surrogates skipped`;
  for (const [name, directory] of [
    ['test262', 'tests/vendor/test262'], ['real_world', 'bench/real_world'],
  ]) {
    const root = path.join(repository, directory);
    assert.ok(fs.existsSync(root), `Missing corpus ${directory}`);
    const { literals, stats } = extractCorpus(root);
    assert.ok(literals.length > 0, `No regexp literals found under ${directory}`);
    corpora.push({ name, literals, note: describe(stats), snapshot: true });
  }
  corpora.push({
    name: 'grammar', literals: patterns.grammarPatterns, note: 'in-tree list', snapshot: true,
  });
  corpora.push({
    name: 'properties', literals: patterns.propertyPatterns(repository),
    note: 'every name in the Odin property tables, in every position', snapshot: true,
  });
  corpora.push({
    name: 'generated', literals: patterns.generatedPatterns(40000),
    note: 'fixed-seed concatenations of grammar fragments', snapshot: true,
  });
  if (oxcCheckout) {
    // Not part of the snapshot: the list belongs to the oxc checkout, which the
    // always-on gate cannot see.
    corpora.push({
      name: 'oxc_tests', literals: oxcCompare.loadOxcPatternLists(oxcCheckout),
      note: 'pattern lists from the oxc checkout', snapshot: false,
    });
  }
  return corpora;
}

function prepareOxc(options) {
  if (!options.oxc) return null;
  const checkout = path.resolve(options.oxc);
  const tool = oxcCompare.buildOxcTool(checkout);
  if (tool === null) {
    console.log(`SKIPPED oxc tree comparison: no oxc checkout at ${checkout}. ` +
      'Trees are checked against the snapshot digests only.');
    assert.ok(!options.update, '--update needs a usable oxc checkout');
    return null;
  }
  oxcCompare.proveOxcDeviations();
  return { checkout, tool };
}

function runCorpus(corpus, oxc, state) {
  const results = uniquePairs(corpus.literals).map(evaluatePair);
  const node = checkNodeAgreement(corpus.name, results, state);
  console.log(`${corpus.name}: ${corpus.literals.length} patterns, ${results.length} unique ` +
    `(pattern, flags); Node agree ${node.agree}, disagree ${node.disagree}, listed deviations ` +
    `${node.listed}, skipped for older Unicode ${node.olderOracle} [${corpus.note}]`);
  if (node.olderOracle !== 0) {
    console.log(`WARNING ${corpus.name}: Node has Unicode ${process.versions.unicode}, older ` +
      `than the tables' ${patterns.TABLE_UNICODE_VERSION}; ${node.olderOracle} property ` +
      'escapes were not checked');
  }
  if (corpus.snapshot) state.digests[corpus.name] = corpusDigests(results);
  if (oxc) {
    const counts = oxcCompare.checkOxcAgreement(corpus.name, results,
      oxcCompare.runOxc(oxc.tool, results), state.failures, state.seenOxcDeviations, state.notes);
    console.log(`${corpus.name}: oxc same tree ${counts.same}, both reject ${counts.bothReject}, ` +
      `tree differs ${counts.treeDiffers}, listed tree deviations ${counts.listed}, ` +
      `oxc differs from Node ${counts.oxcDiffersFromNode}, ` +
      `skipped (empty pattern) ${counts.skipped}`);
  }
  return results;
}

function checkListsAreLive(oxc, state) {
  for (const key of patterns.nodeDeviations.keys()) {
    if (!state.seenNodeDeviations.has(key)) {
      state.failures.push(`Node deviation is listed but not in any corpus: ${key}`);
    }
  }
  if (!oxc) return;
  for (const key of oxcCompare.treeDeviations.keys()) {
    if (!state.seenOxcDeviations.has(key)) {
      state.failures.push(`oxc deviation is listed but not in any corpus: ${key}`);
    }
  }
}

function main() {
  const options = parseArguments(process.argv.slice(2));
  checkOracle();
  const state = {
    failures: [], notes: [], digests: {},
    seenNodeDeviations: new Set(), seenOxcDeviations: new Set(),
  };
  const oxc = prepareOxc(options);
  const dump = [];
  for (const corpus of collectCorpora(oxc ? oxc.checkout : null)) {
    const results = runCorpus(corpus, oxc, state);
    if (options.dump) dump.push(...results.map(result => ({ corpus: corpus.name, ...result })));
  }
  checkListsAreLive(oxc, state);
  if (!options.update) {
    const snapshot = fs.existsSync(snapshotPath) ? JSON.parse(fs.readFileSync(snapshotPath)) : {};
    for (const [name, digests] of Object.entries(state.digests)) {
      checkSnapshot(name, digests, snapshot, state.failures);
    }
  }
  if (options.dump) {
    fs.writeFileSync(options.dump, dump.map(entry => JSON.stringify(entry)).join('\n') + '\n');
  }
  if (state.notes.length !== 0) {
    console.log('Patterns where oxc differs from Node and Kessel agrees with Node:');
    for (const note of state.notes) console.log(`  ${note}`);
  }
  if (state.failures.length !== 0) {
    const shown = options.dump ? state.failures : state.failures.slice(0, 100);
    for (const failure of shown) console.error(failure);
    console.error(`${state.failures.length} regexp reference failures`);
    process.exit(1);
  }
  if (options.update) {
    fs.writeFileSync(snapshotPath, JSON.stringify(state.digests, null, 2) + '\n');
    console.log(`Wrote ${path.relative(repository, snapshotPath)}`);
  }
  if (!oxc) {
    console.log('SKIPPED oxc tree comparison (opt-in: task test:regexp:reference). ' +
      'Kessel trees match the oxc-verified snapshot digests.');
  }
  console.log('Regexp reference gate passed');
}

main();
