#!/usr/bin/env node
// Lexical surface verifier.
//
// Generic pass/fail (did the fixture parse?) is not enough for lexical
// fixtures: every file under `tests/fixtures/spec/lexical/` targets a
// specific tokenisation decision, and the *shape* of the resulting AST is
// what proves the tokeniser made the right call. This verifier encodes one
// focused assertion per fixture, against the same kessel JSON output the
// rest of the suite uses.
//
// Each fixture has a matching assertion function in `CHECKS` below:
//   - 001_hashbang_bom              — `Program.hashbang` is a Hashbang node
//   - 002_crlf_restricted_production — `function f` body has 2 stmts (ASI)
//   - 003_identifier_escape_start    — first decl name is the cooked "abc"
//   - 004_identifier_escape_continue — first decl name is the cooked "abc"
//   - 005_comment_regex_boundary     — `/.../` after a comment is a regex
//   - 006_comment_division_boundary  — `/` after a comment is division
//   - 007_numeric_separator_matrix   — `1_000_000` cooks to the number 1e6
//   - 008_template_raw_vs_cooked     — a TemplateLiteral has raw != cooked
//   - 009_zwj_identifier_contexts    — ZWJ in identifier continuation works
//   - 010_unicode_line_terminator    — U+2028 / U+2029 split statements
//
// Each assertion returns `{ ok, reason }`. The baseline locks the per-fixture
// verdict so known parser gaps (e.g. BOM handling) are visible and tracked
// without blocking the gate, and any pass->fail transition is a regression.
//
// Usage:
//   node tests/verifiers/verify_lexical_surfaces.js             # check baseline
//   node tests/verifiers/verify_lexical_surfaces.js --update    # relock
//   node tests/verifiers/verify_lexical_surfaces.js --strict    # fail on any
//                                                               # non-pass
//   node tests/verifiers/verify_lexical_surfaces.js --verbose   # per-fixture

'use strict';
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const ROOT = path.resolve(__dirname, '../..');
const KESSEL = path.join(ROOT, 'bin/kessel');
const FIXTURE_DIR = path.join(ROOT, 'tests/fixtures/spec/lexical');
const BASELINE_PATH = path.join(ROOT, 'tests/baselines/lexical_surfaces_baseline.json');

const UPDATE = process.argv.includes('--update');
const STRICT = process.argv.includes('--strict');
const VERBOSE = process.argv.includes('--verbose');

// Parse `file` with kessel and return the Program AST. Returns `null` if the
// parser crashed or reported parse errors — the caller treats that as an
// assertion failure of its own, separate from the shape assertion.
function parseProgram(file) {
  const r = spawnSync(KESSEL, ['parse', file, '--compact'], {
    encoding: 'utf8',
    maxBuffer: 64 * 1024 * 1024,
    timeout: 10_000,
  });
  if (r.status !== 0) return { program: null, reason: `kessel exit=${r.status}` };
  const firstLine = (r.stdout || '').split('\n')[0];
  if (!firstLine) return { program: null, reason: 'empty stdout' };
  let ast;
  try {
    ast = JSON.parse(firstLine);
  } catch (err) {
    return { program: null, reason: `JSON.parse failed: ${err.message}` };
  }
  // Kessel emits Parse errors on stderr; be strict here because every
  // lexical fixture must parse cleanly for the shape assertion to be
  // meaningful.
  const stderr = r.stderr || '';
  const m = stderr.match(/Parse errors\s*(?:\((\d+)\)|:\s*(\d+))/);
  if (m) {
    const n = parseInt(m[1] || m[2], 10);
    if (n >= 1) return { program: null, reason: `${n} parse error(s)` };
  }
  return { program: ast, reason: null };
}

// ---------------------------------------------------------------------------
// Per-fixture assertions. Each returns { ok, reason }.
// ---------------------------------------------------------------------------

// 001: hashbang captured despite a leading UTF-8 BOM. The BOM (U+FEFF) is a
// format-control character and must be silently discarded BEFORE tokenisation,
// so the `#!...` on the next line should still be recognised as a hashbang
// and land on `Program.hashbang` as a Hashbang node.
function check_001_hashbang_bom(program) {
  const hb = program.hashbang;
  if (hb && typeof hb === 'object' && hb.type === 'Hashbang') {
    return { ok: true, reason: `Program.hashbang is Hashbang ("${String(hb.value).slice(0, 40)}")` };
  }
  if (typeof hb === 'string' && hb.length > 0) {
    // Some tools emit the hashbang value as a string rather than a node.
    return { ok: true, reason: `Program.hashbang is string ("${hb.slice(0, 40)}")` };
  }
  return {
    ok: false,
    reason: 'Program.hashbang is absent after BOM — BOM likely hides the `#!` line',
  };
}

// 002: CRLF line endings + `return` restricted production. ASI must fire
// between `return` and `1`, so the function body has 2 statements.
function check_002_crlf_restricted_production(program) {
  const fn = program.body.find((n) => n.type === 'FunctionDeclaration');
  if (!fn) return { ok: false, reason: 'FunctionDeclaration missing' };
  const body = fn.body && fn.body.body;
  if (!Array.isArray(body)) return { ok: false, reason: 'FunctionDeclaration body is not a BlockStatement' };
  if (body.length !== 2) {
    return { ok: false, reason: `function body has ${body.length} statement(s); expected 2 (ASI split)` };
  }
  const [ret, lit] = body;
  if (ret.type !== 'ReturnStatement' || ret.argument !== null) {
    return { ok: false, reason: `first stmt is ${ret.type} arg=${ret.argument ? 'present' : 'null'}; expected bare return` };
  }
  if (lit.type !== 'ExpressionStatement') {
    return { ok: false, reason: `second stmt is ${lit.type}; expected ExpressionStatement with 1` };
  }
  return { ok: true, reason: 'CRLF ASI split return from the following literal' };
}

// 003/004: identifier escapes decode into the cooked identifier name. The
// AST carries the cooked name on `Identifier.name`; the raw spelling with
// escapes should NOT survive into the binding name.
function firstDeclName(program) {
  const vd = program.body.find((n) => n.type === 'VariableDeclaration');
  if (!vd) return null;
  const d = vd.declarations && vd.declarations[0];
  if (!d || !d.id || d.id.type !== 'Identifier') return null;
  return d.id.name;
}

function check_003_identifier_escape_start(program) {
  const name = firstDeclName(program);
  if (name === 'abc') return { ok: true, reason: `first declarator name is cooked "abc"` };
  return { ok: false, reason: `first declarator name is "${name}"; expected cooked "abc"` };
}

function check_004_identifier_escape_continue(program) {
  const name = firstDeclName(program);
  if (name === 'abc') return { ok: true, reason: `first declarator name is cooked "abc"` };
  return { ok: false, reason: `first declarator name is "${name}"; expected cooked "abc"` };
}

// 005: regex-vs-division boundary with comments between. Each `const` below
// must initialise to a RegExpLiteral (possibly wrapped in a MemberExpression
// or CallExpression chain) rather than a BinaryExpression `/`.
function containsRegExp(node) {
  if (!node || typeof node !== 'object') return false;
  if (node.type === 'Literal' && node.regex) return true;           // acorn/oxc shape
  if (node.type === 'RegExpLiteral') return true;                   // babel shape
  for (const key of ['object', 'callee', 'expression', 'argument']) {
    if (containsRegExp(node[key])) return true;
  }
  return false;
}

function check_005_comment_regex_boundary(program) {
  const decls = program.body
    .filter((n) => n.type === 'VariableDeclaration')
    .flatMap((n) => n.declarations);
  if (decls.length === 0) return { ok: false, reason: 'no VariableDeclarators found' };
  for (const d of decls) {
    if (!containsRegExp(d.init)) {
      return {
        ok: false,
        reason: `declarator "${d.id && d.id.name}" init has no RegExpLiteral; comment/regex boundary mis-tokenised`,
      };
    }
  }
  return { ok: true, reason: `all ${decls.length} initialisers contain a RegExpLiteral` };
}

// 006: same boundary, opposite classification. After an expression that
// could be followed by division, a `/` is division — the initialisers here
// are BinaryExpression with operator '/'.
function check_006_comment_division_boundary(program) {
  const decls = program.body
    .filter((n) => n.type === 'VariableDeclaration')
    .flatMap((n) => n.declarations);
  // Skip the first `const x = 10` since it's a plain literal, not the
  // boundary under test; check the remaining three.
  const boundary = decls.slice(1);
  if (boundary.length < 3) {
    return { ok: false, reason: `expected >=3 boundary declarators; found ${boundary.length}` };
  }
  for (const d of boundary) {
    if (!d.init || d.init.type !== 'BinaryExpression' || d.init.operator !== '/') {
      return {
        ok: false,
        reason: `declarator "${d.id && d.id.name}" init is ${d.init && d.init.type} op=${d.init && d.init.operator}; expected BinaryExpression '/'`,
      };
    }
  }
  return { ok: true, reason: `all ${boundary.length} boundary initialisers are binary division` };
}

// 007: numeric separators strip out of the cooked numeric value.
function check_007_numeric_separator_matrix(program) {
  const want = {
    decimal: 1_000_000,
    hex: 0xff_ff_ff,
    binary: 0b1010_1010,
    octal: 0o77_77,
    // bigint cooked as BigInt("1000") — checked by presence of bigint field
    // rather than numeric equality because Literal.value for BigInt is a
    // BigInt or a string depending on the parser.
    float: 10.55,
    exponent: 10.55e10,
    neg_exp: 1e-10,
  };
  const decls = program.body
    .filter((n) => n.type === 'VariableDeclaration')
    .flatMap((n) => n.declarations);
  const byName = new Map();
  for (const d of decls) {
    if (d.id && d.id.type === 'Identifier') byName.set(d.id.name, d);
  }
  for (const [name, expected] of Object.entries(want)) {
    const d = byName.get(name);
    if (!d || !d.init) return { ok: false, reason: `declarator "${name}" missing` };
    const got = d.init.value;
    if (Number(got) !== expected) {
      return {
        ok: false,
        reason: `declarator "${name}" cooked value ${got}; expected ${expected}`,
      };
    }
  }
  const bigDecl = byName.get('bigint');
  if (!bigDecl || !bigDecl.init) return { ok: false, reason: 'declarator "bigint" missing' };
  if (bigDecl.init.bigint === undefined && typeof bigDecl.init.value !== 'bigint') {
    return { ok: false, reason: '"bigint" literal does not expose a bigint form' };
  }
  return { ok: true, reason: 'all numeric separators cook correctly' };
}

// 008: templates carry both raw and cooked quasis. Walk every TemplateLiteral
// and confirm at least one has raw !== cooked (which proves the lexer is
// actually computing the cooked form rather than copying the raw bytes).
function findTemplateLiterals(node, out) {
  if (!node || typeof node !== 'object') return;
  if (node.type === 'TemplateLiteral' && Array.isArray(node.quasis)) out.push(node);
  for (const key of Object.keys(node)) {
    const v = node[key];
    if (Array.isArray(v)) for (const x of v) findTemplateLiterals(x, out);
    else if (v && typeof v === 'object') findTemplateLiterals(v, out);
  }
}

function check_008_template_raw_vs_cooked(program) {
  const templates = [];
  findTemplateLiterals(program, templates);
  if (templates.length === 0) return { ok: false, reason: 'no TemplateLiteral nodes' };
  let seenDifference = false;
  for (const t of templates) {
    for (const q of t.quasis) {
      const v = q.value || {};
      if (v.raw !== undefined && v.cooked !== undefined && v.raw !== v.cooked) {
        seenDifference = true;
      }
    }
  }
  if (!seenDifference) {
    return {
      ok: false,
      reason: 'no TemplateElement has raw !== cooked; escapes not decoded',
    };
  }
  return { ok: true, reason: `${templates.length} TemplateLiteral(s), raw/cooked diverge as expected` };
}

// 009: ZWJ (U+200D) inside identifier continuation. The cooked identifier
// name should contain the literal ZWJ character.
function check_009_zwj_identifier_contexts(program) {
  const name = firstDeclName(program);
  if (!name) return { ok: false, reason: 'first declarator name missing' };
  if (!name.includes('\u200D')) {
    return { ok: false, reason: `first declarator name "${name}" has no ZWJ; escape not decoded into identifier` };
  }
  return { ok: true, reason: `first declarator name contains ZWJ: "${name}"` };
}

// 010: U+2028 (LINE SEPARATOR) and U+2029 (PARAGRAPH SEPARATOR) act as
// LineTerminators, so the three `var` declarations separated by them must
// parse as three top-level statements — not one malformed expression.
function check_010_unicode_line_terminator_contexts(program) {
  const vars = program.body.filter((n) => n.type === 'VariableDeclaration');
  if (vars.length === 3) {
    return { ok: true, reason: '3 VariableDeclarations separated by U+2028/U+2029' };
  }
  return {
    ok: false,
    reason: `${vars.length} VariableDeclaration(s) at top level; expected 3`,
  };
}

const CHECKS = {
  '001_hashbang_bom.js': check_001_hashbang_bom,
  '002_crlf_restricted_production.js': check_002_crlf_restricted_production,
  '003_identifier_escape_start.js': check_003_identifier_escape_start,
  '004_identifier_escape_continue.js': check_004_identifier_escape_continue,
  '005_comment_regex_boundary.js': check_005_comment_regex_boundary,
  '006_comment_division_boundary.js': check_006_comment_division_boundary,
  '007_numeric_separator_matrix.js': check_007_numeric_separator_matrix,
  '008_template_raw_vs_cooked.js': check_008_template_raw_vs_cooked,
  '009_zwj_identifier_contexts.js': check_009_zwj_identifier_contexts,
  '010_unicode_line_terminator_contexts.js': check_010_unicode_line_terminator_contexts,
};

function listFixtures() {
  if (!fs.existsSync(FIXTURE_DIR)) {
    console.error(`Error: fixture directory not found at ${FIXTURE_DIR}`);
    process.exit(2);
  }
  return fs.readdirSync(FIXTURE_DIR)
    .filter((n) => n.endsWith('.js'))
    .sort();
}

function main() {
  if (!fs.existsSync(KESSEL)) {
    console.error(`Error: kessel binary not found at ${KESSEL}`);
    process.exit(2);
  }

  const fixtures = listFixtures();
  if (fixtures.length === 0) {
    console.error('No lexical fixtures found.');
    process.exit(2);
  }

  // Sanity: every fixture must have a matching assertion. An unmatched
  // fixture means the verifier is out of sync with the fixture set, which
  // would silently let coverage slip.
  const missingChecks = fixtures.filter((f) => !CHECKS[f]);
  if (missingChecks.length > 0) {
    console.error('Error: fixture(s) without a matching assertion:');
    for (const f of missingChecks) console.error(`  ${f}`);
    process.exit(2);
  }
  const staleChecks = Object.keys(CHECKS).filter((name) => !fixtures.includes(name));
  if (staleChecks.length > 0) {
    console.log('NOTE — assertion entries with no matching fixture on disk:');
    for (const n of staleChecks) console.log(`  ${n}`);
  }

  const current = {};
  const counts = { pass: 0, fail: 0 };
  for (const name of fixtures) {
    const abs = path.join(FIXTURE_DIR, name);
    const { program, reason: parseReason } = parseProgram(abs);
    let verdict;
    if (program === null) {
      verdict = { ok: false, reason: `parse failed: ${parseReason}` };
    } else {
      try {
        verdict = CHECKS[name](program);
      } catch (err) {
        verdict = { ok: false, reason: `check threw: ${err.message}` };
      }
    }
    current[name] = { status: verdict.ok ? 'pass' : 'fail', reason: verdict.reason };
    counts[verdict.ok ? 'pass' : 'fail']++;
    if (VERBOSE) {
      const mark = verdict.ok ? 'OK  ' : 'FAIL';
      console.log(`  ${mark} ${name} — ${verdict.reason}`);
    }
  }

  console.log('');
  console.log(`Lexical surfaces: ${counts.pass}/${fixtures.length} pass, ${counts.fail} fail`);

  if (STRICT) {
    if (counts.fail > 0) {
      console.log('');
      console.log('STRICT mode — every lexical assertion must pass.');
      for (const [name, v] of Object.entries(current)) {
        if (v.status !== 'pass') console.log(`  FAIL ${name}: ${v.reason}`);
      }
      process.exit(1);
    }
    console.log('STRICT mode OK — every lexical assertion passed.');
    process.exit(0);
  }

  const baseline = fs.existsSync(BASELINE_PATH)
    ? JSON.parse(fs.readFileSync(BASELINE_PATH, 'utf8'))
    : null;

  if (UPDATE || baseline === null) {
    fs.writeFileSync(BASELINE_PATH, JSON.stringify(current, null, 2) + '\n');
    console.log(`\nBaseline ${baseline === null ? 'created' : 'updated'}: ${BASELINE_PATH}`);
    if (counts.fail > 0) {
      console.log(`NOTE — ${counts.fail} fixture(s) baselined as fail; these are tracked lexer gaps.`);
    }
    process.exit(0);
  }

  const regressions = [];
  const improvements = [];
  const newFixtures = [];
  for (const name of fixtures) {
    const prev = baseline[name];
    const now = current[name];
    if (prev === undefined) {
      newFixtures.push(`${name} (${now.status})`);
      continue;
    }
    const prevStatus = typeof prev === 'string' ? prev : prev.status;
    if (prevStatus === now.status) continue;
    if (prevStatus === 'pass' && now.status !== 'pass') {
      regressions.push(`${name}: pass -> ${now.status} (${now.reason})`);
    } else if (prevStatus !== 'pass' && now.status === 'pass') {
      improvements.push(`${name}: ${prevStatus} -> pass`);
    }
  }
  const removed = Object.keys(baseline).filter((n) => !(n in current));

  console.log('');
  if (newFixtures.length > 0) {
    console.log(`NEW fixtures: ${newFixtures.length}`);
    for (const n of newFixtures) console.log(`    ${n}`);
  }
  if (removed.length > 0) {
    console.log(`REMOVED: ${removed.length}`);
    for (const n of removed) console.log(`    ${n}`);
  }
  if (improvements.length > 0) {
    console.log(`IMPROVEMENTS: ${improvements.length}`);
    for (const i of improvements) console.log(`    ${i}`);
  }
  if (regressions.length > 0) {
    console.log(`REGRESSIONS: ${regressions.length}`);
    for (const r of regressions) console.log(`    ${r}`);
    console.log('\nFAIL — run with --update after confirming the regressions are intentional.');
    process.exit(1);
  }

  if (newFixtures.length > 0 || improvements.length > 0 || removed.length > 0) {
    console.log('\nOK (with improvements/new/removed) — run with --update to relock.');
  } else {
    console.log('\nOK — matches baseline exactly.');
  }
  process.exit(0);
}

main();
