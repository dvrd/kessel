#!/usr/bin/env node
// OXC conformance-corpus smoke runner (S26 W6 phase 2).
//
// Walks the three corpora `tests/runners/oxc_corpus_fetch.sh` mirrors:
//   * vendor/typescript/tests/cases/{compiler,conformance}/   (.ts / .tsx)
//   * vendor/babel/packages/babel-parser/test/fixtures/       (input.{js,ts,tsx,jsx,mjs})
//   * vendor/estree-conformance/tests/acorn-jsx/pass/         (.jsx + ESTree .json)
//
// Per fixture: derive (dialect, expected-outcome), parse with kessel
// (subprocess) and OXC live (in-process via oxc-parser), classify, count.
//
// The runner is SMOKE-ONLY: exit-code + parse-errors-count vs expected.
// AST walker compare is left for Phase 2b — the smoke baseline tells us
// the shape of the problem first (how many crashes vs mismatches), which
// determines whether walker compare on the surviving subset is worth the
// hour-per-run cost.
//
// Result buckets:
//   pass-both       both kessel and OXC accept (expected: should-parse)
//   reject-both     both reject              (expected: should-throw)
//   ok-vs-oxc       both agree on accept/reject; expected outcome unknown
//                   (TS conformance: most don't have a clean must-pass/must-fail
//                   signal at parser stage, so we accept "kessel agrees with OXC")
//   kessel-only-rejects  OXC accepts, kessel rejects   ← BUG IN KESSEL
//   oxc-only-rejects     kessel accepts, OXC rejects   ← lenience or OXC quirk
//   should-pass-rejected expected accept, both reject  ← legit bug or shared gap
//   should-reject-passed expected reject, both accept  ← shared lenience
//   kessel-crash    kessel exit ≠ 0/1                  ← SIGSEGV / panic
//   oxc-error       OXC threw a non-syntax error (rare; ICU, OOM, etc.)
//   skip-multi-file TS file with ≥ 2 @filename: directives (multi-file project;
//                   first cut doesn't split these into virtual units)
//   skip-other      unsupported extension or read error
//
// Per-suite expectation rules:
//   typescript  no clean parse-stage must-fail signal (TSC's expected errors
//               are type-check / compiler-options errors). First cut: defer
//               to OXC ("ok-vs-oxc"). Multi-file fixtures are skipped.
//   babel       sibling options.json `throws` field marks must-fail. Otherwise
//               must-pass. (Ignores `plugins`; we don't honour Babel's plugin
//               gating — files needing experimental plugins kessel doesn't
//               support land in `should-pass-rejected` if they break, which
//               is fair because OXC also has to follow those rules.)
//   estree     pass/ subset: must-pass (curated by OXC for guaranteed parses).
//
// Usage:
//   node tests/verifiers/verify_oxc_corpus.js [--suite typescript|babel|estree|all]
//                                             [--binary bin/kessel]
//                                             [--filter <substr>]
//                                             [--max-files <N>]
//                                             [--timeout <sec>]
//                                             [--json-out <path>]
//                                             [--verbose]
//                                             [--baseline | --update]
//
// `--baseline` compares against tests/baselines/oxc_corpus_baseline.json;
// `--update` re-captures it. Without either, prints a fresh summary.

'use strict';

const fs = require('fs');
const path = require('path');
const os = require('os');
const { spawn } = require('child_process');

const ROOT = path.resolve(__dirname, '../..');
const VENDOR = path.join(ROOT, 'vendor');
const BASELINE_PATH = path.join(ROOT, 'tests/baselines/oxc_corpus_baseline.json');

const args = parseArgs(process.argv.slice(2));
const KESSEL = path.resolve(args.binary || path.join(ROOT, 'bin/kessel'));
if (!fs.existsSync(KESSEL)) {
  console.error(`kessel binary not found: ${KESSEL}`);
  console.error('Run: task build');
  process.exit(2);
}

// oxc-parser is loaded lazily because it's a native addon and we want a
// clear error if the bench/node_modules tree isn't installed.
let parseSyncOxc;
try {
  parseSyncOxc = require(path.join(ROOT, 'bench/node_modules/oxc-parser')).parseSync;
} catch (err) {
  console.error('oxc-parser not found in bench/node_modules. Run: cd bench && npm install');
  console.error(err.message);
  process.exit(2);
}

// ---------------------------------------------------------------------------
// Fixture discovery
// ---------------------------------------------------------------------------

// A "fixture" is { suite, abs, rel, lang, expected, skipReason }.
//   suite      : 'typescript' | 'babel' | 'estree'
//   abs / rel  : full + suite-relative path
//   lang       : '' | 'jsx' | 'ts' | 'tsx' | 'module'  (passed as --lang= or
//                source-type flag; '' = auto-detect by kessel from extension)
//   expected   : 'pass' | 'fail' | 'unknown'
//   skipReason : null | 'multi-file' | 'unsupported-ext' | 'read-error'
function discoverTypescript() {
  const root = path.join(VENDOR, 'typescript/tests/cases');
  if (!fs.existsSync(root)) return [];
  const out = [];
  walk(root, (abs) => {
    const rel = path.relative(root, abs);
    const ext = path.extname(abs);
    if (ext !== '.ts' && ext !== '.tsx') return;

    let source;
    try { source = fs.readFileSync(abs, 'utf8'); }
    catch { out.push({ suite:'typescript', abs, rel, lang:'', expected:'unknown', skipReason:'read-error' }); return; }

    // Multi-file projects: TSC's "@filename:" directive packs multiple
    // virtual files into one fixture. OXC's tasks/coverage/typescript/meta.rs
    // splits these into TestUnitData[]; we don't, so skip when ≥ 2.
    const filenameDirectives = (source.match(/^\/\/\s*@filename:/gm) || []).length;
    if (filenameDirectives >= 2) {
      out.push({ suite:'typescript', abs, rel, lang:'', expected:'unknown', skipReason:'multi-file' });
      return;
    }

    // Dialect: `.tsx` → tsx, `.ts` → ts. The single-`@filename:` case may
    // override the on-disk extension (e.g. `.ts` file marked as `file.tsx`),
    // so honour it.
    let lang = ext === '.tsx' ? 'tsx' : 'ts';
    const single = source.match(/^\/\/\s*@filename:\s*(\S+)/m);
    if (single) {
      const dirExt = path.extname(single[1]).toLowerCase();
      if (dirExt === '.tsx') lang = 'tsx';
      else if (dirExt === '.ts') lang = 'ts';
      else if (dirExt === '.jsx') lang = 'jsx';
      else if (dirExt === '.js' || dirExt === '.mjs' || dirExt === '.cjs') lang = '';
      // .d.ts and stranger extensions: treat as ts.
    }

    // Most TS conformance tests don't have a clean parser-stage must-fail
    // signal — TSC's expected errors are type-check / compiler-options
    // errors that the *parser* should not flag. Defer to OXC: an
    // "ok-vs-oxc" classification is a pass.
    out.push({ suite:'typescript', abs, rel, lang, expected:'unknown', skipReason:null });
  });
  return out;
}

function discoverBabel() {
  const root = path.join(VENDOR, 'babel/packages/babel-parser/test/fixtures');
  if (!fs.existsSync(root)) return [];
  const out = [];
  walk(root, (abs) => {
    const base = path.basename(abs);
    if (!base.startsWith('input.')) return;
    const ext = path.extname(abs).slice(1);  // js / ts / tsx / jsx / mjs
    if (!['js','ts','tsx','jsx','mjs'].includes(ext)) {
      out.push({ suite:'babel', abs, rel: path.relative(root, abs), lang:'', expected:'unknown', skipReason:'unsupported-ext' });
      return;
    }
    // options.json sibling — `throws` field flags must-fail.
    const optionsPath = path.join(path.dirname(abs), 'options.json');
    let expected = 'pass';
    if (fs.existsSync(optionsPath)) {
      try {
        const opts = JSON.parse(fs.readFileSync(optionsPath, 'utf8'));
        if (typeof opts.throws === 'string') expected = 'fail';
      } catch {/* malformed options.json → assume pass */}
    }
    let lang = '';
    if (ext === 'tsx') lang = 'tsx';
    else if (ext === 'ts') lang = 'ts';
    else if (ext === 'jsx') lang = 'jsx';
    // .js / .mjs: kessel auto-detects from extension; .mjs implies module.
    out.push({ suite:'babel', abs, rel: path.relative(root, abs), lang, expected, skipReason:null, ext });
  });
  return out;
}

function discoverEstree() {
  const root = path.join(VENDOR, 'estree-conformance/tests/acorn-jsx/pass');
  if (!fs.existsSync(root)) return [];
  const out = [];
  for (const entry of fs.readdirSync(root)) {
    if (!entry.endsWith('.jsx')) continue;
    out.push({
      suite: 'estree',
      abs: path.join(root, entry),
      rel: entry,
      lang: 'jsx',
      expected: 'pass',
      skipReason: null,
    });
  }
  return out;
}

function walk(dir, visit) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (entry.name.startsWith('.')) continue;
    const abs = path.join(dir, entry.name);
    if (entry.isDirectory()) walk(abs, visit);
    else if (entry.isFile()) visit(abs);
  }
}

// ---------------------------------------------------------------------------
// Per-fixture run: kessel subprocess + OXC inline. Worker pool below
// orchestrates them.
// ---------------------------------------------------------------------------

// Spawn kessel parse, return { exit, parseErrs, crashed, timeout }. Stdout
// is the AST JSON; we only care about the trailing "Parse errors: N" line
// in stderr (or stdout, when stderr is merged).
function runKessel(fixture) {
  return new Promise((resolve) => {
    const cliArgs = ['parse', fixture.abs, '--compact'];
    if (fixture.lang) cliArgs.push(`--lang=${fixture.lang}`);

    const proc = spawn(KESSEL, cliArgs, { stdio: ['ignore','pipe','pipe'] });
    let stderr = '';
    let timeout = false;

    // 5 s hard cap per file. Most parses are < 50 ms; >5 s is either
    // a pathological fixture or a kessel hang.
    const tid = setTimeout(() => { timeout = true; try { proc.kill('SIGKILL'); } catch {} }, args.timeout * 1000);

    // stdout is the JSON AST — discard, but drain so the pipe doesn't fill.
    proc.stdout.on('data', () => {});
    proc.stderr.on('data', (chunk) => { stderr += chunk.toString('utf8'); });

    proc.on('close', (code, signal) => {
      clearTimeout(tid);
      const m = stderr.match(/Parse errors:\s*(\d+)/);
      const parseErrs = m ? parseInt(m[1], 10) : 0;
      const exit = code != null ? code : -1;
      // exit 0 = ran (may have parse errors). exit 1 = ran with errors that
      // bubbled past the main entrypoint. Anything else = crash.
      const crashed = (exit !== 0 && exit !== 1) || signal != null;
      resolve({ exit, parseErrs, crashed, timeout, signal });
    });
    proc.on('error', (err) => {
      clearTimeout(tid);
      resolve({ exit:-1, parseErrs:0, crashed:true, timeout:false, error:err.message });
    });
  });
}

// Run OXC inline. Returns { ok, errCount, threw }. `errCount` mirrors
// kessel's parseErrs (OXC reports a similar `errors` array; we compare
// length, not contents).
function runOxc(fixture, source) {
  // OXC infers JS/JSX/TS/TSX from the filename extension, but our
  // fixtures don't always have one (or have a misleading one — e.g. TS
  // single-`@filename:` overrides). Synthesize a name with the expected
  // dialect so OXC's grammar fires the same way kessel's does.
  const base = path.basename(fixture.abs);
  let synthName = base;
  if (fixture.lang === 'tsx' && !base.endsWith('.tsx')) synthName = base.replace(/\.[^.]+$/, '.tsx');
  else if (fixture.lang === 'ts' && !base.endsWith('.ts'))  synthName = base.replace(/\.[^.]+$/, '.ts');
  else if (fixture.lang === 'jsx' && !base.endsWith('.jsx')) synthName = base.replace(/\.[^.]+$/, '.jsx');

  try {
    const result = parseSyncOxc(synthName, source, { preserveParens: false });
    return { ok: result.errors.length === 0, errCount: result.errors.length, threw:false };
  } catch (err) {
    return { ok:false, errCount:0, threw:true, error: err.message };
  }
}

// ---------------------------------------------------------------------------
// Worker pool: parallel kessel spawns + inline OXC compare.
// ---------------------------------------------------------------------------

async function runAll(fixtures) {
  const concurrency = Math.min(os.cpus().length, 16);
  const results = new Array(fixtures.length);

  let next = 0;
  let inflight = 0;
  let done = 0;
  const startedAt = Date.now();
  const total = fixtures.length;
  let progressLogAt = Date.now();

  return new Promise((resolve) => {
    function trySpawn() {
      while (inflight < concurrency && next < total) {
        const i = next++;
        inflight++;
        runOne(i).then(() => {
          inflight--; done++;
          if (Date.now() - progressLogAt > 2000) {
            const pct = ((done/total)*100).toFixed(1);
            const eta = total > done ? Math.round(((Date.now()-startedAt)/done)*(total-done)/1000) : 0;
            process.stderr.write(`  ${done}/${total}  (${pct}%, ETA ${eta}s)\n`);
            progressLogAt = Date.now();
          }
          if (done === total) resolve(results);
          else trySpawn();
        });
      }
    }
    trySpawn();
  });

  async function runOne(i) {
    const fix = fixtures[i];

    if (fix.skipReason) {
      results[i] = { fix, verdict: `skip-${fix.skipReason}` };
      return;
    }

    let source;
    try { source = fs.readFileSync(fix.abs, 'utf8'); }
    catch (err) { results[i] = { fix, verdict: 'skip-read-error' }; return; }

    const [k, o] = await Promise.all([runKessel(fix), Promise.resolve(runOxc(fix, source))]);

    results[i] = { fix, verdict: classify(fix, k, o), k, o };
  }
}

function classify(fix, k, o) {
  if (k.crashed) return 'kessel-crash';
  if (k.timeout) return 'kessel-timeout';
  if (o.threw)   return 'oxc-error';

  const kAccepts = k.parseErrs === 0;
  const oAccepts = o.ok;

  // Both reject: agreement. If expected fail → pass; if expected pass → both
  // are wrong (shared gap or genuinely-broken fixture); if unknown → ok.
  if (!kAccepts && !oAccepts) {
    if (fix.expected === 'fail') return 'reject-both';
    if (fix.expected === 'pass') return 'should-pass-rejected';
    return 'ok-vs-oxc';
  }
  // Both accept: agreement.
  if (kAccepts && oAccepts) {
    if (fix.expected === 'fail') return 'should-reject-passed';
    if (fix.expected === 'pass') return 'pass-both';
    return 'ok-vs-oxc';
  }
  // Disagreement.
  if (!kAccepts && oAccepts) return 'kessel-only-rejects';
  return 'oxc-only-rejects';
}

// ---------------------------------------------------------------------------
// Aggregation + output
// ---------------------------------------------------------------------------

function summarize(results) {
  // `bySuite[suite].verdicts[verdict] = count`. Plus a flat `verdicts`
  // map for the overall view. Plus per-suite-subdir failure counts so
  // `kessel-only-rejects` clusters surface (W5b: bug classes cluster).
  const out = { totalFiles: results.length, verdicts:{}, bySuite:{}, bySubdir:{} };

  for (const r of results) {
    out.verdicts[r.verdict] = (out.verdicts[r.verdict] || 0) + 1;
    const suite = r.fix.suite;
    out.bySuite[suite] = out.bySuite[suite] || { total:0, verdicts:{} };
    out.bySuite[suite].total++;
    out.bySuite[suite].verdicts[r.verdict] = (out.bySuite[suite].verdicts[r.verdict] || 0) + 1;

    // Subdir cluster key — first two path components from suite root.
    if (r.verdict !== 'pass-both' && r.verdict !== 'reject-both' && r.verdict !== 'ok-vs-oxc') {
      const parts = r.fix.rel.split(path.sep);
      const subdir = `${suite}/${parts.slice(0, Math.min(2, parts.length-1)).join('/')}`;
      out.bySubdir[subdir] = out.bySubdir[subdir] || {};
      out.bySubdir[subdir][r.verdict] = (out.bySubdir[subdir][r.verdict] || 0) + 1;
    }
  }
  return out;
}

function printSummary(summary) {
  console.log('');
  console.log(`OXC corpus smoke results: ${summary.totalFiles} fixtures`);
  console.log('');

  console.log('Overall verdicts:');
  for (const [v, c] of Object.entries(summary.verdicts).sort((a,b)=>b[1]-a[1])) {
    console.log(`  ${v.padEnd(24)} ${String(c).padStart(7)}`);
  }
  console.log('');

  console.log('Per suite:');
  for (const [suite, s] of Object.entries(summary.bySuite)) {
    const passed = (s.verdicts['pass-both'] || 0) + (s.verdicts['reject-both'] || 0) + (s.verdicts['ok-vs-oxc'] || 0);
    const rate = s.total > 0 ? ((passed / s.total) * 100).toFixed(1) : '0.0';
    console.log(`  ${suite.padEnd(12)} ${passed}/${s.total} agree-with-OXC (${rate}%)`);
    for (const [v, c] of Object.entries(s.verdicts).sort((a,b)=>b[1]-a[1])) {
      if (v === 'pass-both' || v === 'reject-both' || v === 'ok-vs-oxc') continue;
      console.log(`     ${v.padEnd(22)} ${String(c).padStart(6)}`);
    }
  }
  console.log('');

  // Top failure clusters — where bug classes likely live.
  const clusters = Object.entries(summary.bySubdir)
    .map(([k,v]) => [k, Object.values(v).reduce((a,b)=>a+b,0), v])
    .sort((a,b)=>b[1]-a[1])
    .slice(0, 15);
  if (clusters.length > 0) {
    console.log('Top 15 failure clusters (subdir → counts by verdict):');
    for (const [subdir, total, breakdown] of clusters) {
      const parts = Object.entries(breakdown).map(([v,c])=>`${v}=${c}`).join('  ');
      console.log(`  ${subdir.padEnd(45)} ${String(total).padStart(5)}  (${parts})`);
    }
  }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

(async () => {
  const want = (suite) => args.suite === 'all' || args.suite === suite;
  let fixtures = [];
  if (want('typescript')) fixtures.push(...discoverTypescript());
  if (want('babel'))      fixtures.push(...discoverBabel());
  if (want('estree'))     fixtures.push(...discoverEstree());

  if (args.filter) fixtures = fixtures.filter(f => f.rel.includes(args.filter) || f.suite.includes(args.filter));
  if (args.maxFiles) fixtures = fixtures.slice(0, args.maxFiles);

  if (fixtures.length === 0) {
    console.error('No fixtures discovered. Did you run `task test:oxc-corpus:fetch`?');
    process.exit(2);
  }

  console.error(`Walking ${fixtures.length} fixtures across ${[...new Set(fixtures.map(f=>f.suite))].join(', ')}...`);

  const t0 = Date.now();
  const results = await runAll(fixtures);
  const elapsedSec = ((Date.now() - t0) / 1000).toFixed(1);
  console.error(`Done in ${elapsedSec}s.`);

  const summary = summarize(results);
  printSummary(summary);

  if (args.jsonOut) {
    const failures = results
      .filter(r => r.verdict.startsWith('kessel-') || r.verdict === 'should-pass-rejected' || r.verdict === 'oxc-only-rejects')
      .slice(0, 500)
      .map(r => ({ suite:r.fix.suite, file:r.fix.rel, verdict:r.verdict,
                   kErrs: r.k && r.k.parseErrs, oErrs: r.o && r.o.errCount,
                   exit: r.k && r.k.exit, signal: r.k && r.k.signal }));
    fs.writeFileSync(args.jsonOut, JSON.stringify({
      summary, failures, generated_at: new Date().toISOString(),
    }, null, 2));
    console.error(`Wrote JSON to ${args.jsonOut}`);
  }

  if (args.update) {
    fs.mkdirSync(path.dirname(BASELINE_PATH), { recursive:true });
    fs.writeFileSync(BASELINE_PATH, JSON.stringify(summary, null, 2));
    console.error(`Updated baseline → ${path.relative(ROOT, BASELINE_PATH)}`);
    process.exit(0);
  }

  if (args.baseline) {
    if (!fs.existsSync(BASELINE_PATH)) {
      console.error(`No baseline at ${BASELINE_PATH}. Run with --update to capture.`);
      process.exit(2);
    }
    const prev = JSON.parse(fs.readFileSync(BASELINE_PATH, 'utf8'));
    // Guard: --baseline must compare apples to apples. A subset run
    // (--suite, --filter, --max-files) would otherwise show false
    // "improvements" because the snapshot has fewer files than the
    // baseline. Force a full-corpus run.
    if (summary.totalFiles !== prev.totalFiles) {
      console.error(`Baseline file count mismatch: now=${summary.totalFiles} baseline=${prev.totalFiles}`);
      console.error(`--baseline requires a full-corpus run; remove --suite/--filter/--max-files,`);
      console.error(`or run --update if the corpus itself has been re-fetched.`);
      process.exit(2);
    }
    let regressions = 0;
    // Critical buckets: any growth fails.
    const watched = ['kessel-crash','kessel-timeout','kessel-only-rejects','should-pass-rejected'];
    for (const v of watched) {
      const now = summary.verdicts[v] || 0;
      const was = prev.verdicts[v] || 0;
      if (now > was) {
        console.error(`  REGRESSION  ${v}: ${was} → ${now} (+${now-was})`);
        regressions++;
      } else if (now < was) {
        console.error(`  improvement ${v}: ${was} → ${now} (${now-was})`);
      }
    }
    if (regressions > 0) {
      console.error(`\nFAIL: ${regressions} bucket(s) regressed`);
      process.exit(1);
    }
    console.error('Baseline OK');
  }

  // Exit 1 only on crashes when no baseline gating; otherwise 0.
  if (!args.baseline && !args.update) {
    process.exit(summary.verdicts['kessel-crash'] > 0 ? 1 : 0);
  }
})().catch(err => {
  console.error('Driver error:', err);
  process.exit(2);
});

// ---------------------------------------------------------------------------

function parseArgs(argv) {
  const out = { suite:'all', timeout:5, verbose:false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--suite')          out.suite = argv[++i];
    else if (a === '--binary')    out.binary = argv[++i];
    else if (a === '--filter')    out.filter = argv[++i];
    else if (a === '--max-files') out.maxFiles = parseInt(argv[++i], 10);
    else if (a === '--timeout')   out.timeout = parseInt(argv[++i], 10);
    else if (a === '--json-out')  out.jsonOut = argv[++i];
    else if (a === '--baseline')  out.baseline = true;
    else if (a === '--update')    out.update = true;
    else if (a === '--verbose')   out.verbose = true;
  }
  return out;
}
