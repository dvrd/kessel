#!/usr/bin/env node
// Deep family differential verifier.
//
// This gate groups verify_json_deep.js results by fixture family so the suite
// can say more than "some files diverged". Each family gets a compact summary
// with file count, pass count, fail count, and total divergence count.
//
// Why this exists: run_spec_fixtures.js gives us a broad pass-rate gate, but
// when we want to reason about reference-parser drift in a specific syntax
// family, a flat per-file list is noisy. This verifier keeps the pressure on
// the same deep-compare path while making the product surface visible by
// family.
//
// Usage:
//   node tests/verifiers/verify_deep_families.js
//   node tests/verifiers/verify_deep_families.js --families jsx,typescript
//   node tests/verifiers/verify_deep_families.js --parser oxc
//   node tests/verifiers/verify_deep_families.js --update
//   node tests/verifiers/verify_deep_families.js --verbose
//
// Exit 0 when the current summaries match the locked baseline. Exit 1 when
// any family changes and --update was not used.

'use strict';
const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

const ROOT = path.resolve(__dirname, '../..');
const BASELINE_PATH = path.join(ROOT, 'tests/baselines/deep_families_baseline.json');
const FIX_ROOT = path.join(ROOT, 'tests/fixtures/spec');
const PARSER_CHOICES = new Set(['oxc', 'acorn', 'babel']);
const DEFAULT_FAMILIES = [
  'ambiguity',
  'asi',
  'escapes',
  'interactions',
  'jsx',
  'lexical',
  'regex_disambiguation',
  'typescript',
  'unicode',
];

const args = process.argv.slice(2);
const UPDATE = args.includes('--update');
const VERBOSE = args.includes('--verbose');

function readOption(name, fallback) {
  const prefix = `${name}=`;
  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (arg === name) {
      return i + 1 < args.length ? args[i + 1] : fallback;
    }
    if (arg.startsWith(prefix)) {
      return arg.slice(prefix.length);
    }
  }
  return fallback;
}

const PARSER = readOption('--parser', 'oxc');
if (!PARSER_CHOICES.has(PARSER)) {
  console.error(`Unknown --parser "${PARSER}"; expected oxc|acorn|babel`);
  process.exit(2);
}

const FAMILY_LIST = readOption('--families', DEFAULT_FAMILIES.join(','))
  .split(',')
  .map((name) => name.trim())
  .filter((name) => name.length > 0);

if (FAMILY_LIST.length === 0) {
  console.error('No families selected.');
  process.exit(2);
}

function listFamilyFiles(family) {
  const familyDir = path.join(FIX_ROOT, family);
  if (!fs.existsSync(familyDir) || !fs.statSync(familyDir).isDirectory()) {
    throw new Error(`missing fixture family: ${family}`);
  }

  const files = [];
  function walk(dir) {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true }).sort((a, b) => {
      return a.name.localeCompare(b.name);
    })) {
      const abs = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        walk(abs);
        continue;
      }
      if (!entry.name.endsWith('.js')) continue;
      files.push(abs);
    }
  }

  walk(familyDir);
  return files;
}

// `verify_json_deep.js` picks the right dialect from the file path on both
// the Kessel and OXC sides, so we don't thread a CLI flag through here.
// Any new dialect-detection rules go there (single source of truth).
function runDeepCompare(file) {
  try {
    execSync(
      `node tests/verifiers/verify_json_deep.js "${file}" --parser ${PARSER} --limit 0`,
      { encoding: 'utf8', maxBuffer: 32 * 1024 * 1024 },
    );
    return { pass: true, divergences: 0 };
  } catch (error) {
    const output = `${error.stdout || ''}${error.stderr || ''}`;
    const match = output.match(/(\d+) divergence\(s\) vs/);
    if (match) {
      return { pass: false, divergences: parseInt(match[1], 10) };
    }
    return { pass: false, divergences: 1 };
  }
}

function summarizeFamily(family) {
  const files = listFamilyFiles(family);
  const summary = { files: files.length, pass: 0, fail: 0, divergences: 0 };

  for (const file of files) {
    const result = runDeepCompare(file);
    if (result.pass) {
      summary.pass++;
    } else {
      summary.fail++;
      summary.divergences += result.divergences;
    }

    if (VERBOSE) {
      const rel = path.relative(ROOT, file);
      const verdict = result.pass ? 'OK  ' : 'FAIL';
      const detail = result.pass ? 'passes vs reference' : `${result.divergences} divergence(s)`;
      console.log(`  ${verdict} ${rel} — ${detail}`);
    }
  }

  return summary;
}

function loadBaseline() {
  if (!fs.existsSync(BASELINE_PATH)) return null;
  return JSON.parse(fs.readFileSync(BASELINE_PATH, 'utf8'));
}

function sameSummary(a, b) {
  return a.files === b.files
    && a.pass === b.pass
    && a.fail === b.fail
    && a.divergences === b.divergences;
}

const current = {
  parser: PARSER,
  families: FAMILY_LIST,
  summaries: {},
};

console.log('Deep family compliance');
console.log(`Parser: ${PARSER}`);
console.log(`Families: ${FAMILY_LIST.join(', ')}`);
console.log(`Baseline: ${BASELINE_PATH}${UPDATE ? ' [UPDATE MODE]' : ''}`);
console.log('');

for (const family of FAMILY_LIST) {
  current.summaries[family] = summarizeFamily(family);
}

console.log('Family summaries:');
for (const family of FAMILY_LIST) {
  const s = current.summaries[family];
  console.log(
    `  ${family}: ${s.pass}/${s.files} pass, ${s.fail} fail, ` +
    `${s.divergences} divergence(s)`,
  );
}

const baseline = loadBaseline();
if (UPDATE || baseline === null) {
  fs.writeFileSync(BASELINE_PATH, JSON.stringify(current, null, 2) + '\n');
  console.log(`\nBaseline ${baseline === null ? 'created' : 'updated'}: ${BASELINE_PATH}`);
  process.exit(0);
}

const changes = [];
if (baseline.parser !== current.parser) {
  changes.push(`parser: ${baseline.parser} -> ${current.parser}`);
}

const baselineFamilies = baseline.families || [];
if (baselineFamilies.join(',') !== current.families.join(',')) {
  changes.push(`families: ${baselineFamilies.join(', ')} -> ${current.families.join(', ')}`);
}

for (const family of current.families) {
  const prev = baseline.summaries && baseline.summaries[family];
  const now = current.summaries[family];
  if (!prev) {
    changes.push(`${family}: new family`);
    continue;
  }
  if (!sameSummary(prev, now)) {
    changes.push(
      `${family}: ${prev.pass}/${prev.files} pass, ${prev.fail} fail, ` +
      `${prev.divergences} divergence(s) -> ` +
      `${now.pass}/${now.files} pass, ${now.fail} fail, ` +
      `${now.divergences} divergence(s)`,
    );
  }
}

for (const family of baselineFamilies) {
  if (!current.summaries[family]) {
    changes.push(`${family}: removed family`);
  }
}

console.log('');
if (changes.length > 0) {
  console.log(`CHANGES: ${changes.length}`);
  for (const change of changes) console.log(`  ${change}`);
  console.log('  Re-run with --update to relock.');
  process.exit(1);
}

console.log('OK — matches baseline exactly.');
process.exit(0);
