#!/usr/bin/env node
// Recovery surface verifier.
//
// These fixtures are intentionally malformed, but they still need to preserve
// the later anchor declaration/function so we can measure how well the parser
// recovers instead of only checking whether it crashes.
//
// The verifier checks four things for every fixture:
//   1. the parse completes without crashing,
//   2. at least one parse error is reported, but not an absurd number,
//   3. the anchor identifier survives in the emitted AST,
//   4. the tree stays structurally sane (no Unknown explosions, no span leaks).
//
// Usage:
//   node tests/verifiers/verify_recovery.js
//   node tests/verifiers/verify_recovery.js --verbose

'use strict';
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const ROOT = path.resolve(__dirname, '../..');
const KESSEL = path.join(ROOT, 'bin/kessel');
const RECOVERY_DIRS = [
  'tests/fixtures/recovery/expressions',
  'tests/fixtures/recovery/statements',
  'tests/fixtures/recovery/declarations',
  'tests/fixtures/recovery/jsx_ts',
];
const VERBOSE = process.argv.includes('--verbose');
const MAX_PARSE_ERRORS = 10;
const ANCHOR_NAME = 'anchor_after_error';

const LANG_BY_FILE = {
  '001_jsx_attr_broken.js': 'jsx',
  '002_jsx_close_tag_broken.js': 'jsx',
  '003_ts_type_annotation_broken.js': 'ts',
  '004_ts_assertion_broken.js': 'ts',
  '005_generic_param_broken.js': 'ts',
};

function listFixtures() {
  const out = [];
  for (const dir of RECOVERY_DIRS) {
    const absDir = path.join(ROOT, dir);
    if (!fs.existsSync(absDir)) continue;
    for (const entry of fs.readdirSync(absDir, { withFileTypes: true }).sort((a, b) => {
      return a.name.localeCompare(b.name);
    })) {
      if (!entry.isFile() || !entry.name.endsWith('.js')) continue;
      out.push({
        abs: path.join(absDir, entry.name),
        rel: path.join(dir, entry.name),
        lang: LANG_BY_FILE[entry.name] || 'js',
      });
    }
  }
  return out;
}

function parseParseErrors(text) {
  const match = text.match(/Parse errors:\s*(\d+)/);
  if (!match) return 0;
  return parseInt(match[1], 10);
}

function walkNodes(node, visit, parent = null, pathStr = 'program') {
  if (node == null) return;
  if (Array.isArray(node)) {
    for (let i = 0; i < node.length; i++) {
      walkNodes(node[i], visit, parent, `${pathStr}[${i}]`);
    }
    return;
  }
  if (typeof node !== 'object') return;
  visit(node, parent, pathStr);
  const nextParent = typeof node.start === 'number' && typeof node.end === 'number'
    ? node
    : parent;
  for (const key of Object.keys(node)) {
    if (key === 'type' || key === 'start' || key === 'end' || key === 'loc' || key === 'range') {
      continue;
    }
    if (key === 'comments' && node.type === 'Program') continue;
    walkNodes(node[key], visit, nextParent, `${pathStr}.${key}`);
  }
}

function walkEdges(node, visit) {
  walkNodes(node, (current, parent, p) => {
    if (!parent) return;
    if (p.includes('.typeAnnotation')) return;
    if (typeof current.start !== 'number' || typeof current.end !== 'number') return;
    if (typeof parent.start !== 'number' || typeof parent.end !== 'number') return;
    visit(parent, current, p);
  });
}

function countUnknownNodes(tree) {
  let count = 0;
  walkNodes(tree, (node) => {
    if (node.type === 'Unknown') count++;
  });
  return count;
}

function hasAnchor(tree) {
  let found = false;
  walkNodes(tree, (node) => {
    if (found) return;
    if (node && node.type === 'Identifier' && node.name === ANCHOR_NAME) {
      found = true;
    }
  });
  return found;
}

function parseFixture(fixture) {
  const args = ['parse'];
  if (fixture.lang === 'jsx') args.push('--lang=jsx');
  if (fixture.lang === 'ts') args.push('--lang=ts');
  args.push(fixture.abs);

  const result = spawnSync(KESSEL, args, {
    encoding: 'utf8',
    maxBuffer: 16 * 1024 * 1024,
    timeout: 10_000,
  });

  const stdout = result.stdout || '';
  const stderr = result.stderr || '';
  const parseErrors = parseParseErrors(stderr);
  if (result.status !== 0) {
    return {
      ok: false,
      status: result.status,
      reason: `crash exit=${result.status}`,
      parseErrors,
    };
  }

  const errorsMarker = stdout.indexOf('\nParse errors (');
  const jsonText = errorsMarker === -1 ? stdout : stdout.slice(0, errorsMarker);

  let tree;
  try {
    tree = JSON.parse(jsonText);
  } catch (error) {
    return {
      ok: false,
      status: result.status,
      reason: `invalid JSON output: ${error.message}`,
      parseErrors,
    };
  }

  return {
    ok: true,
    status: result.status,
    parseErrors,
    tree,
  };
}

function checkFixture(fixture) {
  const parsed = parseFixture(fixture);
  if (!parsed.ok) {
    return parsed;
  }

  if (parsed.parseErrors < 1) {
    return {
      ok: false,
      reason: 'expected at least one parse error',
      parseErrors: parsed.parseErrors,
    };
  }
  if (parsed.parseErrors > MAX_PARSE_ERRORS) {
    return {
      ok: false,
      reason: `too many parse errors: ${parsed.parseErrors}`,
      parseErrors: parsed.parseErrors,
    };
  }

  if (!hasAnchor(parsed.tree)) {
    return {
      ok: false,
      reason: `missing anchor ${ANCHOR_NAME}`,
      parseErrors: parsed.parseErrors,
    };
  }

  const unknownNodes = countUnknownNodes(parsed.tree);
  if (unknownNodes > 0) {
    return {
      ok: false,
      reason: `unknown node(s): ${unknownNodes}`,
      parseErrors: parsed.parseErrors,
    };
  }

  let spanViolations = 0;
  walkEdges(parsed.tree, (parent, child, p) => {
    if (child.start < parent.start || child.end > parent.end) {
      spanViolations++;
      if (VERBOSE && spanViolations <= 5) {
        console.log(
          `  span leak ${fixture.rel} ${p}: parent=${parent.type}[${parent.start}..${parent.end}] ` +
          `child=${child.type}[${child.start}..${child.end}]`,
        );
      }
    }
  });

  if (spanViolations > 0) {
    return {
      ok: false,
      reason: `span violations: ${spanViolations}`,
      parseErrors: parsed.parseErrors,
    };
  }

  return {
    ok: true,
    parseErrors: parsed.parseErrors,
  };
}

const fixtures = listFixtures();
if (fixtures.length === 0) {
  console.error('No recovery fixtures found.');
  process.exit(2);
}

let pass = 0;
const failures = [];
for (const fixture of fixtures) {
  const result = checkFixture(fixture);
  if (result.ok) {
    pass++;
    if (VERBOSE) {
      console.log(`  OK   ${fixture.rel} — ${result.parseErrors} parse error(s), anchor survived`);
    }
    continue;
  }
  failures.push({ rel: fixture.rel, reason: result.reason });
  console.log(`  FAIL ${fixture.rel} — ${result.reason}`);
}

console.log('');
console.log('Recovery fixtures:');
console.log(`  pass: ${pass}`);
console.log(`  fail: ${failures.length}`);
console.log(`  total: ${fixtures.length}`);

if (failures.length > 0) {
  process.exit(1);
}

console.log('Recovery gate OK — anchors survived and spans stayed sane.');
process.exit(0);
