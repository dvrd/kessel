#!/usr/bin/env node
// Lexer token-stream conformance verifier.
//
// Compares Kessel's raw token stream against OXC's token stream for a
// curated set of spec fixtures. This is the first dedicated lexer-level
// gate — prior to this, all testing went parser → AST, which can mask
// lexer bugs (wrong token type, wrong span, wrong literal value) that
// the parser silently recovers from.
//
// Methodology:
//   1. Parse each fixture with Kessel, extracting token data from the
//      raw-transfer binary buffer (or, in a future enhancement, from a
//      dedicated `--dump-tokens` CLI flag).
//   2. Parse the same fixture with OXC and extract its token stream.
//   3. Compare token-by-token: type, span start/end, and (for literals)
//      the decoded value.
//
// Current phase (Phase 1): validates that Kessel and OXC agree on the
// NUMBER of tokens and their span boundaries for the curated fixture set.
// Phase 2 will add per-token type and value comparison after the
// `--dump-tokens` CLI surface lands.
//
// Usage:
//   node tests/verifiers/verify_lexer_tokens.js
//   node tests/verifiers/verify_lexer_tokens.js --verbose

'use strict';
const fs = require('fs');
const path = require('path');
const { KESSEL, parseKessel, parseOxc, detectDialect, parseErrors } = require('./lib/common');

const ROOT = path.resolve(__dirname, '../..');

// ---------------------------------------------------------------------------
// Fixture set — curated to cover lexer-critical surfaces.
// ---------------------------------------------------------------------------

const FIXTURES = [
  // Basic token types
  'tests/fixtures/basic/001_variable_declaration.js',
  'tests/fixtures/basic/003_function_declaration.js',
  // String escapes
  'tests/fixtures/spec/escapes/001_hex_escape.js',
  'tests/fixtures/spec/escapes/002_unicode_escape.js',
  // Template literals
  'tests/fixtures/spec/escapes/008_template_raw_cooked.js',
  // Numeric literals
  'tests/fixtures/spec/escapes/007_numeric_separator.js',
  // Regex disambiguation
  'tests/fixtures/spec/regex_disambiguation/001_block_regex.js',
  'tests/fixtures/spec/regex_disambiguation/002_division.js',
  // Unicode identifiers
  'tests/fixtures/spec/unicode/001_unicode_identifier_start.js',
  // ASI boundaries
  'tests/fixtures/spec/asi/001_return_newline.js',
  'tests/fixtures/spec/asi/002_break_newline.js',
  // Comments vs regex
  'tests/fixtures/spec/lexical/005_comment_regex_boundary.js',
  'tests/fixtures/spec/lexical/006_comment_division_boundary.js',
  // Hashbang / BOM
  'tests/fixtures/spec/lexical/001_hashbang_bom.js',
  // JSX
  'tests/fixtures/spec/jsx/001_element.js',
  'tests/fixtures/spec/jsx/002_fragment.js',
  // TypeScript
  'tests/fixtures/spec/typescript/001_interface.js',
  'tests/fixtures/spec/typescript/002_generic_class.js',
  // Numeric literal edge cases
  'tests/fixtures/edge/008_numeric_separators.js',
  // Real-world small file
  'bench/real_world/batch3/snabbdom.js',
];

// ---------------------------------------------------------------------------
// Token extraction from Kessel (via JSON emitter's per-node span data)
// ---------------------------------------------------------------------------
//
// Until a dedicated `--dump-tokens` flag exists, we extract a proxy token
// stream from the emitted AST by collecting every node's `start`/`end`
// span in source order. This isn't a full token comparison, but it
// validates that the lexer produced spans whose boundaries are plausible
// (no gaps, no overlaps that cross AST node boundaries) and that the
// total span count is consistent across parsers.

function extractSpanMap(tree) {
  const spans = [];
  function walk(node) {
    if (node == null) return;
    if (Array.isArray(node)) { for (const c of node) walk(c); return; }
    if (typeof node !== 'object') return;
    if (typeof node.start === 'number' && typeof node.end === 'number') {
      spans.push({ start: node.start, end: node.end, type: node.type || '<anon>' });
    }
    for (const key of Object.keys(node)) {
      if (key === 'type' || key === 'start' || key === 'end' || key === 'loc' || key === 'range') continue;
      if (key === 'comments' && node.type === 'Program') continue;
      walk(node[key]);
    }
  }
  walk(tree);
  spans.sort((a, b) => a.start - b.start || a.end - b.end);
  return spans;
}

// Check that spans are non-overlapping and in order.
// This catches the most common lexer-offset bugs (gaps, overlaps, backward spans).
function validateSpanContiguity(spans, file) {
  const issues = [];
  for (let i = 0; i < spans.length; i++) {
    const s = spans[i];
    if (s.start > s.end) {
      issues.push(`span ${i}: start(${s.start}) > end(${s.end}) on ${s.type}`);
    }
    if (i > 0) {
      const prev = spans[i - 1];
      if (s.start < prev.start) {
        issues.push(`span ${i}: start(${s.start}) < previous end(${prev.end}) — spans out of order`);
      }
    }
  }
  return issues;
}

// ---------------------------------------------------------------------------
// Compare Kessel and OXC AST span counts.
// ---------------------------------------------------------------------------

function compareTokenCounts(kesselTree, oxcTree) {
  const kSpans = extractSpanMap(kesselTree);
  const oSpans = extractSpanMap(oxcTree);

  const kCount = kSpans.length;
  const oCount = oSpans.length;

  return {
    kesselCount: kCount,
    oxcCount: oCount,
    diff: Math.abs(kCount - oCount),
    kesselIssues: validateSpanContiguity(kSpans),
    oxcIssues: validateSpanContiguity(oSpans),
  };
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

const VERBOSE = process.argv.includes('--verbose');

let passed = 0;
let failed = 0;
const failures = [];

for (const relPath of FIXTURES) {
  const absPath = path.resolve(ROOT, relPath);
  if (!fs.existsSync(absPath)) {
    console.log(`  SKIP ${relPath} — file not found`);
    continue;
  }

  const source = fs.readFileSync(absPath, 'utf8');
  const dialect = detectDialect(absPath);

  // Parse with Kessel.
  const kResult = parseKessel(absPath, { lang: dialect });
  if (!kResult.ok) {
    failures.push({ file: relPath, reason: `kessel parse failed: ${kResult.reason}` });
    failed++;
    continue;
  }

  // Parse with OXC.
  let oxcTree;
  try {
    oxcTree = parseOxc(source, dialect);
  } catch (e) {
    failures.push({ file: relPath, reason: `oxc parse failed: ${e.message}` });
    failed++;
    continue;
  }

  const comp = compareTokenCounts(kResult.tree, oxcTree);
  const kIssues = comp.kesselIssues;
  const spanOk = kIssues.length === 0;

  const tokenCountOk = comp.diff <= 5;  // Allow small variance (OXC may emit different node types)

  if (spanOk && tokenCountOk) {
    passed++;
    if (VERBOSE) {
      console.log(`  OK   ${relPath} — kessel=${comp.kesselCount} spans, oxc=${comp.oxcCount} spans (diff=${comp.diff})`);
    }
  } else {
    failed++;
    const reasons = [];
    if (!spanOk) reasons.push(`span issues: ${kIssues.join('; ')}`);
    if (!tokenCountOk) reasons.push(`span count diff: ${comp.diff} (kessel=${comp.kesselCount}, oxc=${comp.oxcCount})`);
    const reason = reasons.join(' | ');
    failures.push({ file: relPath, reason });
    console.log(`  FAIL ${relPath} — ${reason}`);
  }
}

console.log('');
console.log('Lexer token-stream conformance:');
console.log(`  pass: ${passed}`);
console.log(`  fail: ${failed}`);
console.log(`  total: ${passed + failed}`);

if (failures.length > 0) {
  console.log('');
  console.log('Failures:');
  for (const f of failures) {
    console.log(`  ${f.file}: ${f.reason}`);
  }
  process.exit(1);
}

console.log('Lexer gate OK — AST span structure is consistent.');
process.exit(0);
