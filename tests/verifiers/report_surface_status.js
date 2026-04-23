#!/usr/bin/env node
// Product-surface status reporter.
//
// Reads `tests/surface_status.json` and prints a compact per-surface summary:
//   - declared coverage status (strong/medium/weak) and policy
//   - fixture counts computed by walking the declared fixture dirs
//   - baseline snapshots (pass/fail counts) extracted from the
//     baseline files this suite already maintains
//   - a consolidated "known failing surfaces" block at the end
//
// This is a reporter, NOT a gate: it always exits 0 on valid config, and
// exits 2 on configuration errors (missing config file, unreadable JSON,
// surfaces pointing to nonexistent dirs). The point is to make product
// confidence visible in one place so the answer to "what do we cover and
// how well?" isn't scattered across baselines.
//
// Usage:
//   node tests/verifiers/report_surface_status.js
//   node tests/verifiers/report_surface_status.js --json   # raw machine output
//   node tests/verifiers/report_surface_status.js --surface ambiguity_ts_jsx

'use strict';
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '../..');
const CONFIG_PATH = path.join(ROOT, 'tests/surface_status.json');

const AS_JSON = process.argv.includes('--json');
const VERBOSE = process.argv.includes('--verbose');

function readSurfaceArg() {
  for (let i = 2; i < process.argv.length; i++) {
    const arg = process.argv[i];
    if (arg === '--surface' && i + 1 < process.argv.length) return process.argv[i + 1];
    if (arg.startsWith('--surface=')) return arg.slice('--surface='.length);
  }
  return null;
}
const SURFACE_FILTER = readSurfaceArg();

function die(code, msg) {
  console.error(msg);
  process.exit(code);
}

function readConfig() {
  if (!fs.existsSync(CONFIG_PATH)) die(2, `Error: ${CONFIG_PATH} not found`);
  let raw;
  try {
    raw = JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8'));
  } catch (err) {
    die(2, `Error: failed to parse ${CONFIG_PATH}: ${err.message}`);
  }
  if (!raw || !Array.isArray(raw.surfaces)) {
    die(2, `Error: ${CONFIG_PATH} must contain a top-level "surfaces" array`);
  }
  return raw;
}

// Walk a fixture directory and count `.js` files. Non-existent dirs are
// reported as an error — a stale config is as much a coverage claim as a
// missing fixture. Skipping a missing dir silently would hide that.
function countFixtures(dir, errors) {
  const abs = path.join(ROOT, dir);
  if (!fs.existsSync(abs)) {
    errors.push(`fixture_dir does not exist: ${dir}`);
    return 0;
  }
  if (!fs.statSync(abs).isDirectory()) {
    errors.push(`fixture_dir is not a directory: ${dir}`);
    return 0;
  }
  let count = 0;
  const stack = [abs];
  while (stack.length > 0) {
    const current = stack.pop();
    for (const entry of fs.readdirSync(current, { withFileTypes: true })) {
      const childAbs = path.join(current, entry.name);
      if (entry.isDirectory()) {
        stack.push(childAbs);
        continue;
      }
      if (entry.isFile() && entry.name.endsWith('.js')) count++;
    }
  }
  return count;
}

// Try to summarise a baseline file based on its extension and shape. We
// support the two shapes the suite uses today:
//   - JSON objects where every value is a status string (e.g. negative,
//     test262_subset per_file, lexical_surfaces, ambiguity)
//   - JSON objects with a `summaries` subtree (deep_families)
//   - JSON objects with per-category `{pass, fail, total}` (spec_fixtures)
//   - plain-text lists (known-failures)
// Anything else falls back to "file present, shape not recognised".
function summarizeBaseline(baselinePath, errors) {
  const abs = path.join(ROOT, baselinePath);
  if (!fs.existsSync(abs)) {
    errors.push(`baseline does not exist: ${baselinePath}`);
    return { kind: 'missing' };
  }
  const ext = path.extname(abs).toLowerCase();
  if (ext === '.txt') {
    const lines = fs.readFileSync(abs, 'utf8').split(/\r?\n/);
    let entries = 0;
    for (const line of lines) {
      const t = line.trim();
      if (t && !t.startsWith('#')) entries++;
    }
    return { kind: 'txt-list', entries };
  }
  if (ext !== '.json') return { kind: 'unknown' };

  let data;
  try {
    data = JSON.parse(fs.readFileSync(abs, 'utf8'));
  } catch (err) {
    errors.push(`baseline JSON parse failed: ${baselinePath}: ${err.message}`);
    return { kind: 'unreadable' };
  }

  // Shape 1: { per_file: { <k>: <status> }, by_category: { ... }, overall: { ... } }
  if (data && typeof data === 'object' && data.overall && data.by_category) {
    return {
      kind: 'category-overall',
      overall: data.overall,
      by_category: data.by_category,
    };
  }

  // Shape 2: { <category>: { pass, fail, total } } — spec_fixtures baseline.
  if (
    data
    && typeof data === 'object'
    && Object.values(data).every(
      (v) => v && typeof v === 'object'
        && typeof v.pass === 'number'
        && typeof v.total === 'number'
    )
  ) {
    let pass = 0, fail = 0, total = 0;
    for (const v of Object.values(data)) {
      pass += v.pass || 0;
      fail += v.fail || 0;
      total += v.total || 0;
    }
    return {
      kind: 'category-totals',
      overall: { pass, fail, total },
      by_category: data,
    };
  }

  // Shape 3: { summaries: { <family>: { files, pass, fail, divergences } } }
  if (data && data.summaries && typeof data.summaries === 'object') {
    let pass = 0, fail = 0, total = 0;
    for (const v of Object.values(data.summaries)) {
      pass += v.pass || 0;
      fail += v.fail || 0;
      total += v.files || 0;
    }
    return {
      kind: 'family-summaries',
      overall: { pass, fail, total },
      by_family: data.summaries,
    };
  }

  // Shape 4: { <key>: "pass" | "fail" | "rejected" | "accepted" | ... }
  if (
    data
    && typeof data === 'object'
    && Object.values(data).every((v) => typeof v === 'string')
  ) {
    const tally = {};
    for (const v of Object.values(data)) tally[v] = (tally[v] || 0) + 1;
    return { kind: 'flat-tally', tally, total: Object.keys(data).length };
  }

  // Shape 5: { <key>: { status: "pass"|"fail", reason: "..." } }
  if (
    data
    && typeof data === 'object'
    && Object.values(data).every(
      (v) => v && typeof v === 'object' && typeof v.status === 'string'
    )
  ) {
    const tally = {};
    for (const v of Object.values(data)) tally[v.status] = (tally[v.status] || 0) + 1;
    return { kind: 'flat-tally', tally, total: Object.keys(data).length };
  }

  return { kind: 'unrecognised' };
}

function formatBaseline(summary) {
  switch (summary.kind) {
    case 'missing':
      return '(baseline file missing)';
    case 'unreadable':
      return '(baseline unreadable)';
    case 'unknown':
    case 'unrecognised':
      return '(baseline present, shape not recognised)';
    case 'txt-list':
      return `${summary.entries} entry/entries`;
    case 'flat-tally': {
      const parts = Object.entries(summary.tally)
        .sort(([a], [b]) => a.localeCompare(b))
        .map(([k, v]) => `${k}=${v}`);
      return `${parts.join(' ')} (total=${summary.total})`;
    }
    case 'category-overall': {
      const o = summary.overall;
      return `overall pass=${o.pass}/${o.total} known_fail=${o.known_fail || 0} unexpected_fail=${o.unexpected_fail || 0}`;
    }
    case 'category-totals': {
      const o = summary.overall;
      return `overall pass=${o.pass}/${o.total} fail=${o.fail}`;
    }
    case 'family-summaries': {
      const o = summary.overall;
      return `overall pass=${o.pass}/${o.total} fail=${o.fail}`;
    }
    default:
      return `(unknown kind: ${summary.kind})`;
  }
}

const CONFIDENCE_ORDER = ['weak', 'medium', 'strong'];

function formatStatusPill(status) {
  const label = CONFIDENCE_ORDER.includes(status) ? status : '?';
  return `[${label.padEnd(6)}]`;
}

function main() {
  const cfg = readConfig();
  const errors = [];
  const rows = [];

  const surfaces = SURFACE_FILTER
    ? cfg.surfaces.filter((s) => s.name === SURFACE_FILTER)
    : cfg.surfaces;
  if (SURFACE_FILTER && surfaces.length === 0) {
    die(2, `Error: no surface named "${SURFACE_FILTER}" in ${CONFIG_PATH}`);
  }

  for (const surface of surfaces) {
    const fixtureCounts = {};
    let totalFixtures = 0;
    for (const dir of surface.fixture_dirs || []) {
      const n = countFixtures(dir, errors);
      fixtureCounts[dir] = n;
      totalFixtures += n;
    }

    const baselineSummaries = {};
    for (const baseline of surface.baselines || []) {
      baselineSummaries[baseline] = summarizeBaseline(baseline, errors);
    }

    rows.push({
      name: surface.name,
      description: surface.description,
      coverage_status: surface.coverage_status,
      policy: surface.policy,
      verifiers: surface.verifiers || [],
      fixture_counts: fixtureCounts,
      fixture_total: totalFixtures,
      baselines: baselineSummaries,
      notes: surface.notes || '',
    });
  }

  if (AS_JSON) {
    console.log(JSON.stringify({ surfaces: rows, config_errors: errors }, null, 2));
    process.exit(errors.length > 0 ? 2 : 0);
  }

  // Human-readable output. Column widths kept small so the summary fits in a
  // standard terminal; `--verbose` adds per-dir and per-baseline detail.
  const namePad = Math.max(...rows.map((r) => r.name.length), 4);
  console.log('Surface status');
  console.log('==============');
  console.log('');
  for (const row of rows) {
    console.log(
      `${formatStatusPill(row.coverage_status)} ${row.name.padEnd(namePad)}  ` +
      `policy=${row.policy}  fixtures=${row.fixture_total}  verifiers=${row.verifiers.length}  baselines=${Object.keys(row.baselines).length}`,
    );
    if (VERBOSE) {
      console.log(`    desc: ${row.description}`);
      if (row.verifiers.length > 0) {
        console.log(`    verifiers:`);
        for (const v of row.verifiers) console.log(`      - ${v}`);
      }
      if (row.fixture_total > 0) {
        console.log(`    fixtures:`);
        for (const [dir, n] of Object.entries(row.fixture_counts)) {
          console.log(`      - ${dir}: ${n}`);
        }
      }
      for (const [b, s] of Object.entries(row.baselines)) {
        console.log(`    baseline ${b}`);
        console.log(`      ${formatBaseline(s)}`);
      }
      if (row.notes) console.log(`    notes: ${row.notes}`);
      console.log('');
    }
  }

  // Known-failing surfaces: anything not declared "strong" gets its status
  // summarised here for quick visibility, with notes if any.
  const weak = rows.filter((r) => r.coverage_status === 'weak');
  const medium = rows.filter((r) => r.coverage_status === 'medium');
  if (weak.length > 0 || medium.length > 0) {
    console.log('');
    console.log('Coverage gaps');
    console.log('-------------');
    for (const r of weak) {
      console.log(`  [weak]   ${r.name}  — ${r.notes || '(no notes)'}`);
    }
    for (const r of medium) {
      console.log(`  [medium] ${r.name}  — ${r.notes || '(no notes)'}`);
    }
  }

  if (errors.length > 0) {
    console.log('');
    console.log('Configuration errors');
    console.log('--------------------');
    for (const e of errors) console.log(`  ${e}`);
    process.exit(2);
  }

  process.exit(0);
}

main();
