#!/usr/bin/env node
// Multi-file TS fixture splitter + smoke verifier.
//
// Processes the ~3,500 TypeScript fixtures that pack multiple virtual files
// via `// @filename:` directives. Splits each fixture at directive boundaries,
// writes virtual files to a temp dir, runs kessel + OXC on each, and reports
// disagreements (kessel-only-rejects).
//
// Usage:
//   node tests/verifiers/verify_multifile.js [--max-files N] [--verbose]

'use strict';
const fs = require('fs');
const path = require('path');
const os = require('os');
const { spawnSync } = require('child_process');

const ROOT = path.resolve(__dirname, '../..');
const KESSEL = path.join(ROOT, 'bin/kessel');
const VENDOR = path.join(ROOT, 'vendor');

let parseSyncOxc;
try {
  parseSyncOxc = require(path.join(ROOT, 'bench/node_modules/oxc-parser')).parseSync;
} catch {
  console.error('oxc-parser not found. Run: cd bench && npm install oxc-parser');
  process.exit(1);
}

// ---------------------------------------------------------------------------
// CLI args
// ---------------------------------------------------------------------------
const argv = process.argv.slice(2);
const maxFiles = (() => { const i = argv.indexOf('--max-files'); return i >= 0 ? parseInt(argv[i+1], 10) : Infinity; })();
const verbose = argv.includes('--verbose');
const filterArg = (() => { const i = argv.indexOf('--filter'); return i >= 0 ? argv[i+1] : null; })();

// ---------------------------------------------------------------------------
// Multi-file splitter
// ---------------------------------------------------------------------------

// Split a TS fixture source into virtual files.
// Returns [{ filename: string, source: string, lang: string }]
// The preamble (before the first @filename) is discarded (it's TSC options).
function splitMultiFile(source) {
  const units = [];
  const lines = source.split(/\r?\n/);
  let currentFile = null;
  let currentLines = [];

  for (const line of lines) {
    const m = line.match(/^\/\/\s*@filename:\s*(\S+)/i);
    if (m) {
      // Flush previous unit
      if (currentFile) {
        units.push({ filename: currentFile, source: currentLines.join('\n') });
      }
      currentFile = m[1];
      currentLines = [];
    } else if (currentFile) {
      currentLines.push(line);
    }
    // Lines before the first @filename are TSC options — discard.
  }
  // Flush last unit
  if (currentFile) {
    units.push({ filename: currentFile, source: currentLines.join('\n') });
  }
  return units;
}

function isDeclarationFilename(filename) {
  const lower = filename.toLowerCase();
  return lower.endsWith('.d.ts') || lower.endsWith('.d.mts') ||
         lower.endsWith('.d.cts') || /\.d\.[^.]+\.ts$/.test(lower);
}

function langFromFilename(filename) {
  const lower = filename.toLowerCase();
  if (isDeclarationFilename(lower)) return 'ts';
  const ext = path.extname(lower);
  if (ext === '.tsx') return 'tsx';
  if (ext === '.jsx') return 'jsx';
  if (ext === '.ts' || ext === '.mts' || ext === '.cts') return 'ts';
  return '';  // .js / .mjs / .cjs → auto-detect
}

// ---------------------------------------------------------------------------
// Discover multi-file fixtures
// ---------------------------------------------------------------------------

function discoverMultiFile() {
  const root = path.join(VENDOR, 'typescript/tests/cases');
  if (!fs.existsSync(root)) return [];
  const out = [];

  function walk(dir) {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) { walk(full); continue; }
      const ext = path.extname(entry.name);
      if (ext !== '.ts' && ext !== '.tsx') continue;

      let source;
      try { source = fs.readFileSync(full, 'utf8'); } catch { continue; }

      const directives = (source.match(/^\/\/\s*@filename:/gmi) || []).length;
      if (directives < 2) continue;

      const rel = path.relative(root, full);
      if (filterArg && !rel.includes(filterArg)) continue;

      out.push({ abs: full, rel, source });
      if (out.length >= maxFiles) return;
    }
  }
  walk(root);
  return out;
}

// ---------------------------------------------------------------------------
// Run parsers
// ---------------------------------------------------------------------------

function runKesselOnSource(source, lang, tmpFile) {
  fs.mkdirSync(path.dirname(tmpFile), { recursive: true });
  fs.writeFileSync(tmpFile, source, 'utf8');
  const args = ['parse', tmpFile, '--compact'];
  if (lang) args.push(`--lang=${lang}`);
  const r = spawnSync(KESSEL, args, { timeout: 5000, stdio: ['ignore', 'pipe', 'pipe'] });
  const stderr = (r.stderr || '').toString();
  const m = stderr.match(/Parse errors:\s*(\d+)/);
  return { errs: m ? parseInt(m[1], 10) : 0, crashed: r.status !== 0 && r.status !== 1 };
}

function tmpFilenameForUnit(filename, index) {
  const lower = filename.toLowerCase();
  if (isDeclarationFilename(lower)) return path.join(tmpDir, `unit-${index}.d.ts`);
  const ext = path.extname(lower) || '.ts';
  return path.join(tmpDir, `unit-${index}${ext}`);
}

function runOxcOnSource(source, filename) {
  try {
    const r = parseSyncOxc(filename, source, { preserveParens: false });
    return { errs: r.errors.length, crashed: false };
  } catch {
    return { errs: 0, crashed: true };
  }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

const fixtures = discoverMultiFile();
console.log(`Found ${fixtures.length} multi-file fixtures.`);

const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'kessel-multifile-'));

let totalUnits = 0;
let agreeUnits = 0;
let kesselOnlyRejects = 0;
let oxcOnlyRejects = 0;
let bothReject = 0;
let crashes = 0;

const kesselOnlyFiles = [];  // [{ fixture, unit, kErrs, oErrs }]

const startTime = Date.now();

for (let fi = 0; fi < fixtures.length; fi++) {
  const fix = fixtures[fi];
  const units = splitMultiFile(fix.source);

  for (const unit of units) {
    const lang = langFromFilename(unit.filename);
    const synthName = unit.filename;
    const tmpFile = tmpFilenameForUnit(unit.filename, totalUnits);

    const k = runKesselOnSource(unit.source, lang, tmpFile);
    const o = runOxcOnSource(unit.source, synthName);

    totalUnits++;

    if (k.crashed) { crashes++; continue; }
    if (o.crashed) { continue; }

    const kOk = k.errs === 0;
    const oOk = o.errs === 0;

    if (kOk === oOk) {
      agreeUnits++;
      if (!kOk) bothReject++;
    } else if (!kOk && oOk) {
      kesselOnlyRejects++;
      kesselOnlyFiles.push({ rel: fix.rel, filename: unit.filename, kErrs: k.errs });
    } else {
      oxcOnlyRejects++;
    }
  }

  if ((fi + 1) % 500 === 0 || fi === fixtures.length - 1) {
    const pct = (((fi+1) / fixtures.length) * 100).toFixed(1);
    const elapsed = ((Date.now() - startTime) / 1000).toFixed(1);
    process.stderr.write(`  ${fi+1}/${fixtures.length}  (${pct}%)  ${elapsed}s  units=${totalUnits}\n`);
  }
}

// Cleanup
try { fs.rmSync(tmpDir, { recursive: true, force: true }); } catch {}

// Report
console.log(`\nMulti-file corpus results:`);
console.log(`  Fixtures:           ${fixtures.length}`);
console.log(`  Virtual files:      ${totalUnits}`);
console.log(`  Agree (both ok):    ${agreeUnits - bothReject}`);
console.log(`  Agree (both reject):${bothReject}`);
console.log(`  kessel-only-rejects:${kesselOnlyRejects}`);
console.log(`  oxc-only-rejects:   ${oxcOnlyRejects}`);
console.log(`  crashes:            ${crashes}`);
console.log(`  Time:               ${((Date.now() - startTime)/1000).toFixed(1)}s`);

if (kesselOnlyFiles.length > 0) {
  console.log(`\n--- kessel-only-rejects (${kesselOnlyFiles.length}) ---`);
  // Cluster by first error
  const byFixture = {};
  for (const f of kesselOnlyFiles) {
    const key = f.rel;
    if (!byFixture[key]) byFixture[key] = [];
    byFixture[key].push(f);
  }
  const sorted = Object.entries(byFixture).sort((a,b) => b[1].length - a[1].length);
  for (const [rel, files] of sorted.slice(0, verbose ? 100 : 20)) {
    console.log(`  ${rel}:`);
    for (const f of files.slice(0, 3)) {
      // Re-run to capture the first error message. Preserve the virtual
      // filename suffix so `.d.ts` declaration-file relaxations still apply.
      const lang = langFromFilename(f.filename);
      const unit = splitMultiFile(fixtures.find(fx => fx.rel === rel).source).find(u => u.filename === f.filename);
      if (unit) {
        const errTmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'kessel-mf-err-'));
        const tmpF2 = path.join(errTmpDir, path.basename(tmpFilenameForUnit(f.filename, `err`)));
        fs.writeFileSync(tmpF2, unit.source, 'utf8');
        const r = spawnSync(KESSEL, ['parse', tmpF2, '--compact', ...(lang ? ['--lang='+lang] : [])],
          { timeout: 5000, stdio: ['ignore', 'pipe', 'pipe'] });
        const stderr = (r.stderr || '').toString();
        const errLine = stderr.match(/Line \d+.*?:\s*(.*)/);
        console.log(`    ${f.filename} (${f.kErrs} errs)${errLine ? ': ' + errLine[1] : ''}`);
        try { fs.rmSync(errTmpDir, { recursive: true, force: true }); } catch {}
      } else {
        console.log(`    ${f.filename} (${f.kErrs} errs)`);
      }
    }
    if (files.length > 3) console.log(`    ... and ${files.length - 3} more`);
  }
}

process.exit(kesselOnlyRejects > 0 ? 1 : 0);
