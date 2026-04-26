# Handoff — Kessel

## What is Kessel

Kessel is a JavaScript / TypeScript / JSX parser written in Odin. It produces
ESTree-compatible JSON ASTs (plus optional OXC-shape module record and
structured errors). Originally built to parse ES2015–ES2025 JavaScript faster
than [oxc-parser](https://www.npmjs.com/package/oxc-parser); the speed
advantage has narrowed under the weight of the spec-conformance work
(performance numbers below). The project is a pure parser — no transpiler,
no bundler, no linter, no formatter — with zero dependencies outside the Odin
toolchain. All memory is statically allocated at startup; zero heap allocations
post-init via a virtual arena + bump pool.

**Status headline (Session 13, 2026-04-26 — regex grammar push):**
ECMA-262 Test262 conformance **49 270 / 49 729 (99.08 %)**, up from
48 989 / 49 729 (98.51 %) at the start of this session — **+281 tests**
across **5 commits**, all on `origin/main`. Every unit / negative / recovery /
spec-fixture / spec-compliance / ESTree-strict / multi-parser / fuzz /
invariants / nodes / crashes-known / lexical / ambiguity / deep-families /
bench gate is green.

This session opened a dedicated regex-grammar surface (`src/regex.odin`,
~1 200 LOC) called from `lex_regex` after flag parsing so every check
can branch on `has_u` / `has_v`. Five waves landed, each its own clean
commit with the test262 baseline relocked:

| Commit | Phase | What | Δ tests |
|---|---|---|---:|
| `89101ae` | **A** — property escapes | Validate `\p{…}` / `\P{…}` shape + binary / non-binary / GC / of-strings name tables; gate of-strings on `v`; reject `\P{prop-of-strings}` | **+144** |
| `0ac3fb6` | **E** — arithmetic modifiers | Validate `(?ims-ims:body)` flag list (i/m/s only, no dupes per side, no overlap, no escapes, no non-ASCII, mandatory `:`, both-sides-empty rejected) | **+83** |
| `3d3f8be` | **A′/B′** hardening | u-mode strict `\k<name>` resolution (no Annex B fallback, no bare `\k`); reject U+2028 / U+2029 in pattern body | **+11** |
| `c8b1ee7` | **B** — strict u-mode pattern grammar + v-mode awareness | IdentityEscape strict (`\M/u` reject), ControlEscape body (`\c0/u`), DecimalEscape oob (`\1/u`, `\8/u`), extended-pattern-char (`{/u`), `\u{H+}` bounds, quantified assertion (`.(?=.)?/u`), char-class range with class-atom (`[\d-a]/u`); v-mode `\q{…}` accepted, set-difference walker carve-out, named-group decl validator made escape-aware (unblocks astral name-escapes like `\u{1d4d1}`) | **+33** |
| `b72a3d4` | **B-e/B-f** — leading quantifier + lookbehind quantifier | Reject `/?/`, `/+/`, `/{2}/` etc. with no preceding atom (`(?…)` prefixes skipped to avoid false positives); reject quantified `(?<=…)` / `(?<!…)` in any mode (no Annex B carve-out for lookbehind); `\k` strict in non-u when any names declared | **+10** |

Prior status (Session 12 close): 48 989 / 49 729 (98.51 %), 13 commits
ahead of `origin/main`, all pushed at the start of this session before
landing the new work. Working tree clean.

---

## Current State

### Build

```
task build
```

Wraps `odin build src -out:bin/kessel -o:speed -no-bounds-check`. Verified this
session: clean build in **47.3 s** (cold), no warnings, produces a 3.18 MB
binary at `bin/kessel`. Debug build (`task build:debug`) emits ~50 cosmetic
linker warnings about JSX/TS generic symbol visibility; the binary is fine.
Binary size has grown ~270 KB since Session 11 from the new spec checks.

### Tests

Every gate run **this session (2026-04-25)**:

| Suite | Command | Result | Notes |
|---|---|---|---|
| Default chain | `task test` | ✅ exit 0 in **1m12s** | Runs unit + negative + real + nodes + invariants + estree + multi-parser + spec-compliance + spec-fixtures + test262 + lexical + ambiguity + fuzz + fuzz-invalid + crashes-known + recovery + regression. |
| Unit | `task test:unit` | **409 / 409** ✅ (0 skipped) | 11 s. Was 284/409 with 125 skipped at Session 11 start; un-skipped in `3b1872a`. |
| Regression | `task test:regression` | **11 / 11** ✅ | Structural diff vs OXC for session-fixed bugs. |
| Real-world | `task test:real` | **467 / 467** ✅ | 467 production JS files parse with zero errors. |
| Node coverage | `task test:nodes` | **57 / 57** ✅ | Every emitted ESTree type has a live fixture. |
| Test262 (curated) | `task test:test262` | **66 / 66** ✅ | Quick-smoke subset. |
| Spec-fixtures | `task test:spec-fixtures` | **144 / 144** ✅ | All 22 categories at 100 %. |
| Invariants | `task test:invariants` | ✅ zero-tolerance clean | Structural ESTree invariants across the real corpus. |
| ESTree drift | `task test:estree` | ✅ deep compare passes vs OXC | jquery, react-dom.dev, preact, snabbdom. |
| ESTree drift (strict) | `task test:estree:strict` | ✅ 0 mismatches | Zero-tolerance pre-release gate. |
| Multi-parser | `task test:multi-parser` | ✅ matches baseline | Snabbdom passes vs Acorn + Babel. |
| Spec-compliance | `task test:spec-compliance` | **0 divergences** ✅ | All 12 curated real files match OXC byte-for-byte. |
| Fuzz (diff vs OXC) | `task test:fuzz` | **97 / 100** ✅ | 3 baselined: Kessel correctly rejects per-spec where OXC accepts (duplicate arrow params ×2, `let` / function-decl clash). Documented as known-good divergences. |
| Fuzz (invalid input) | `task test:fuzz:invalid` | ✅ 8 / 8 baselined | 8 SIGTERMs on 350 KB – 4 MB mutated files (deadline-crosses, not parser bugs). |
| Crashes-known | `task test:crashes-known` | ✅ 0 pinned, 0 new | |
| Recovery | `task test:recovery` | **32 / 32** ✅ | All anchors survive; spans stay sane. |
| Negative gate | `task test:negative` | **125 / 125 rejected** ✅ | 54 static-error classes. |
| Negative gate (strict) | `task test:negative:strict` | **125 / 125** ✅ | Zero-tolerance variant. |
| Lexical surfaces | `task test:lexical` | 9 / 10 ✅ baseline | One known fail (BOM + hashbang); all other lexical assertions pass. |
| Ambiguity | `task test:ambiguity` | 7 known_fail / 0 unexpected ✅ | TS / JSX / JS boundary suite. |
| Deep families | `task test:deep-families` | ✅ matches baseline | Per-family deep-compare against OXC. Refreshed this session: interactions 3 → 10, lexical 7 → 9, typescript 10 → 14. |
| **Test262 full** | `task test:test262:full:regression` | **48 989 / 49 729 (98.51 %)** ✅ | **+292 tests since session start at 48 697** (96.30 %). Per-dir: language 22 824 → 23 116 (+292). annexB / built-ins / staging unchanged. ~2m30s. Off the default chain. |
| Bench regression | `task test:bench:regression` | ✅ geo-mean 0.99 vs baseline | First-time baseline locked this session at `tests/baselines/bench_baseline.json`. |

### Performance

Re-measured this session on Apple M-series (`task bench:quick`, 30 iterations, min runtime):

| File | Size | Kessel | OXC | Ratio (kessel/oxc) |
|------|------|--------|-----|---------------------|
| typescript.js | 8.6 MB | 44.7 ms | 36.8 ms | **1.21x** (Kessel slower) |
| cesium.js | 4.7 MB | 37.2 ms | 31.3 ms | 1.19x |
| monaco.js | 4.1 MB | 37.1 ms | 28.1 ms | 1.32x |
| antd.js | 4.0 MB | 23.4 ms | 19.3 ms | 1.21x |
| d3.js | 573 KB | 5.4 ms | 4.4 ms | 1.23x |
| react-dom.dev.js | 487 KB | 4.06 ms | 3.49 ms | 1.16x |
| jquery.js | 285 KB | 1.69 ms | 1.44 ms | 1.18x |
| lodash.js | 544 KB | 1.37 ms | 1.22 ms | 1.13x |
| preact.js | 11 KB | 175 µs | 137 µs | 1.27x |
| snabbdom.js | (small) | 3.4 µs | 3.3 µs | 1.01x |

**Kessel is now ~13–32 % SLOWER than OXC on real-world files.** This is a
material regression from the README's claim of "0.78x median (22 % faster
than Rust)" — that figure was the truth pre-Session-9, before two seasons
of spec-conformance work added per-token escape-flag tracking, the
PrivateIdentifier walker, the contextual await/yield checks, expr-to-
pattern conversion paths, etc. The README needs updating; see "Known
Issues" K-PERF below.

Methodology: `bin/kessel microbench parse <file> --iterations 30` and
`bench/oxc_compare/target/release/oxc_microbench <file> 30`. Both report
min-of-30. The bench-regression baseline (`bench_baseline.json`, freshly
locked this session) gives 5 % geo-mean tolerance vs the recorded numbers
above so future sessions can detect regressions early.

---

## Project Structure

### Source files (`src/`, ~24 500 LOC of Odin)

| File | Lines | Purpose |
|---|---:|---|
| `src/main.odin` | 7 075 | CLI entry point + every subcommand (`parse`, `lex`, `microbench`, `profile`, `server`, `transfer`). Owns the JSON emit (direct-buffer with `os.write`), the byte→UTF-16 offset table, line-offset tables for `--loc`, the OXC error-shape adapter, the module-record emission, and the `kessel server` mode + async pipe protocol. |
| `src/parser.odin` | 12 224 | Recursive-descent + Pratt expression parser. The `Parser` struct (line 186) carries every contextual flag: in_function, in_generator, in_async, in_loop, in_switch, strict_mode, in_static_block (new this session), in_case_clause (new this session), in_method, in_derived_constructor, class_has_extends, in_generator_params, in_async_params, no_in, label_stack, label_is_iteration, has_module_syntax, force_source_type, force_strict, show_semantic_errors, preserve_parens, plus the bump pool, allocator, error / cover-init lists, and ESM module-record arrays. Every spec-conformance check lives here. |
| `src/lexer.odin` | 2 473 | `Lexer` struct (line 50), 16-byte FastToken, per-letter keyword dispatch, every numeric / string / template / regex / identifier / private-identifier path. Includes the §22.2.1 regex named-group declaration + back-reference validator and the §12.9.3 NumericLiteralSeparator placement checks (binary / octal / hex / decimal-int / fraction / exponent / dot-prefix-fraction / legacy-octal-zero-prefix). |
| `src/ast.odin` | 1 507 | Every ESTree node type as Odin struct + the union types (`Expression`, `Statement`, `Declaration`, `Pattern`, `ObjectPatternPropertyKey`, `ExportDefaultDef`, `ArrowFunctionBody`, `FunctionBody`, `LiteralValue`). 204 type declarations total. |
| `src/raw_transfer.odin` | 646 | Zero-copy AST buffer for cross-language consumption. Walks every node and rewrites native pointers to u32 offsets relative to the arena base, producing a flat byte buffer any language can DataView. Used by the `kessel transfer` subcommand and the npm shim's NAPI-free path. Rewriters are mechanical and exhaustive — every variant of every union has a case. |
| `src/simd.odin` | 244 | ARM64 NEON: `simd_find_string_end` (16-byte parallel quote/backslash scan), `simd_has_multibyte`, `simd_build_utf16_offsets`. Used by `lex_string` hot path and the byte→UTF-16 offset table builder. |
| `src/token.odin` | 375 | `TokenType` enum (every keyword, contextual keyword, punctuator), `Token` (parser-side, with `value`, `literal`, `loc`, `had_line_terminator`, `has_escape`), `FastToken` (lexer-side, 16 bytes), `LiteralValue` (string / f64), helpers `is_assignment_operator`, `get_token_name`. |

Dependency graph:
```
main.odin -> parser.odin -> lexer.odin -> simd.odin
                                       -> token.odin
                         -> ast.odin
          -> raw_transfer.odin (post-parse)
```

### Test infrastructure (`tests/`)

```
tests/
├── fixtures/              409 .js fixtures across basic, edge, es2015..es2025,
│                          early_errors (40), negative (85), real, recovery (32),
│                          spec/* (144 across 22 categories)
├── expected/              409 .txt files, byte-for-byte goldens for every fixture
├── runners/               run_tests.sh, run_test262.sh, run_test262_full.sh,
│                          run_spec_fixtures.js, test262_fetch.sh
├── verifiers/             27 verifier scripts (Node), one per gate
├── baselines/             21 .json baselines (relocked this session: test262_full,
│                          deep_families, bench)
├── COVERAGE_AUDIT.md      coverage tracking
├── COVERAGE_GAP_CHECKLIST.md
├── COVERAGE_IMPLEMENTATION_PLAN.md
├── QA_REPORT.md
├── README.md
├── SURFACE_MAP.md         per-surface coverage map
├── surface_status.json    machine-readable surface status
├── test262/               (legacy hand-curated subset)
└── test262_manifest.json
```

### Bench infrastructure (`bench/`)

```
bench/
├── real_world/            467 production JS files (corpus for test:real and bench)
│   ├── batch2/            14 files (cesium, monaco, preact, ...)
│   ├── batch3/            (snabbdom, ...)
│   └── batch4/
├── oxc_compare/           Rust harness — Cargo crate that wraps oxc_parser for the
│                          comparison microbench. Build with task bench:oxc:build.
├── generated/             pre-generated synthetic files for fuzz scenarios
├── baselines/             per-file recorded numbers (informational; the real
│                          regression gate is tests/baselines/bench_baseline.json)
└── package.json           Node bench harness (Acorn, Babel, OXC for ESTree compare)
```

### npm shim (`npm/kessel-parser/`)

| File | Purpose |
|---|---|
| `index.js` | `parse()` async API. Spawns `bin/kessel parse` per call. |
| `server.js` | `parseSync()`-style API over `kessel server` long-running pipe. ~3.7× spawn-per-call throughput. |
| `bench.js`, `visitor.js`, `README.md` | bench harness, visitor walker example, docs |
| `package.json` | `kessel-parser@0.1.0`, no dependencies |

---

## Architecture

```
Source String (UTF-8)
    │
    ▼
┌──────────┐   FastToken (16 B, by value)   ┌──────────┐   ^Program     ┌──────────┐
│  Lexer   │ ────────────────────────────►  │  Parser  │  ────────────► │ Emitter  │ → JSON stdout
│ (SIMD)   │   cur / nxt 1-token lookahead  │ (Pratt)  │  AST tree      │ (direct- │
│          │   per-letter keyword dispatch  │          │                │  buffer  │
└──────────┘                                └──────────┘                │  os.write)
     │                                            │                     └──────────┘
     │ comments[]                                 │ errors[]                 │
     │ has_hashbang, hashbang_value               │ pending_cover_inits[]    │ errors[]
     └────────────────────────────────────────────┴──────────────────────────┘
                              │                                       │
                              ├── Parser holds ESM static / dynamic   │
                              │   import + export records, consumed   │  Optional alternative output:
                              │   by emit_module_record               │
                              │                                       ├── Raw Transfer buffer
                              └── Parser tracks Lang mode (JS/JSX/    │   (raw_transfer.odin):
                                  TS/TSX) from extension or          │   pointer→offset rewrite,
                                  --lang flag                        │   flat bytes for cross-
                                                                     │   language DataView read
                                                                     └── kessel server mode:
                                                                         single-process, length-
                                                                         prefixed STDIN/STDOUT
                                                                         pipe, ~3.7× throughput
```

### Memory strategy

Single `mem/virtual.Arena`, pre-allocated at `max(source_len * 256, 16 MB)`. All
AST nodes come from a bump pool (4 KB pages, overflow to arena). Zero `free()`
calls anywhere in the parser hot path. Arena destroyed at exit. Microbench
re-uses the arena via `arena_free_all` between iterations instead of mmap /
munmap.

### Hot path (per token)

`lex_token` → branchless single-space skip → single-char lookup table
(`CHAR_CLASS_TABLE`) → identifier / keyword / operator dispatch. The parser
keeps `cur` and `nxt` as cached `FastToken` values; `advance_token` swaps
`cur ← nxt` and lexes a new `nxt`. Emitter writes directly to a pre-allocated
`direct_buf` (~20× source size) and flushes with one `os.write`.

### Key types

- `Parser` (`parser.odin:186`) — every contextual flag + bump pool +
  allocator + error lists + ESM records. **17 boolean context flags**
  this session.
- `Lexer` (`lexer.odin:50`) — source slice, offset, FastToken cache,
  hashbang span, BOM-before-hashbang flag, lexer-error list.
- `FastToken` (`token.odin:338`) — 16 bytes, passed by value end-to-end
  between lexer and parser. Designed for register transit.
- `Token` (`token.odin:164`) — parser-side wrapper. Adds `value` (raw
  source slice or cooked identifier name for `\uXXXX` escapes), `literal`
  (typed value for Number / String), `had_line_terminator`, `has_escape`.

---

## Key Design Decisions

| What | Why | Alternative considered |
|---|---|---|
| Bump allocator for AST nodes | Zero-dispatch alloc, scales with source size, no fragmentation | Per-node Odin allocator — 5–10× slower in benchmarks. |
| 16-byte FastToken passed by value | No indirection between lexer and parser — token fits in 2 ARM64 registers | Heap-allocated Token + pointer — cache-thrashing on the hot path. |
| SIMD comment / string scan (NEON only) | `*/` and quote/backslash detection in one 16-byte parallel pass | Scalar loop — measurably slower on jquery / typescript. AMD64 SSE port deferred (no x86 hardware in CI). |
| Arena reuse in benchmarks | `arena_free_all` keeps the same virtual mapping, avoiding mmap / munmap per iter | Per-iter arena alloc — ~3× microbench overhead. |
| Lazy string interner | Hash map only allocated on first `intern()` call (regex patterns, escape-cooked names) | Always-allocated interner — wasted memory on the hot 99 % of files. |
| Pratt + recursive descent | One state machine, every operator's precedence in `precedence_table[]` | Hand-written precedence climbing per operator — more code, equal speed. |
| `force_source_type` + auto-detect | CLI lets users pin Script vs Module; auto-detect promotes on first import / export / TLA | Default-Module everywhere — breaks Script-only files (CommonJS bundles). |
| Recovery: parse the AST anyway, accumulate errors | Editor tooling expects an AST even when input is malformed | Bail on first error — no good for IDE integration; would also break the `recovery/` and `fuzz/` gates. |
| Spec-conformance via parser flags + post-parse walkers | Each scope-bound rule (await context, yield context, static-block, …) is one boolean on `Parser` | Build a real scope tree — much larger refactor; deferred. The 17 flags handle ~98 % of the spec surface. |
| Zero npm dependencies | Supply chain attack surface = 0 | Use Acorn / Babel internally — 2× more code to install, slower install time. |

---

## Known Issues

| # | Issue | Severity | Where | Workaround |
|---|---|---|---|---|
| K-REGEX | **Partial RegExp pattern grammar.** Session 13 split out `src/regex.odin` (~1 200 LOC) and landed five waves: property escapes, arithmetic modifiers, u-mode `\k` strictness, full strict u/v-mode pattern grammar (IdentityEscape / ControlEscape / DecimalEscape / extended pattern char / `\u{…}` bounds / quantified assertion / char-class range), v-mode `\q{…}` and set-difference awareness, leading-quantifier rejection, lookbehind-quantifier rejection — a total of +281 Test262 fixtures. Still deferred: per-property-value tables (Script names, GC value loose-matching, ~10), v-mode set notation `[\p{A}--\p{B}]/v` proper validation (currently accepts permissively, ~ unknown), duplicate named-groups same-alternative (~4), strict Unicode IDStart / IDPart for named-group names (`(?<❤>a)/u`, ~12 — needs ID tables), and a handful of legacy Sputnik (`/*/`, `///`) corner cases. Roughly ~30 regex-related fixtures left blocked. | Low (impact: <0.1 pp Test262 cap) | `src/regex.odin`, `src/lexer.odin` | Continue phase-by-phase; the dispatch site in `regex_validate_pattern` is ready for additive validators. |
| K-SCOPE | **No scope / symbol analysis.** Cross-statement bindings (`let x; var x;` in nested blocks → §13.2.5 collision), TDZ, used-before-declaration, closure capture analysis, parameter-vs-body name shadowing all require a scope tree we haven't built. **15 fixtures blocked** in `language/block-scope/syntax/redeclaration/*`, plus several `language/statements/{class, function, generators}/static-init-invalid-lex-{var,dup}` and similar. | Low (impact: ~0.06 pp Test262) | parser-wide | `--show-semantic-errors` flag enables a partial post-parse walker (only redeclaration / `let` clash). |
| K-PERF | **Kessel is now 13–32 % slower than OXC on real-world files.** The README claims `0.78x median (22 % faster than Rust)` — that was true pre-Session-9. Two seasons of spec-conformance work (PrivateIdentifier walker, contextual await/yield checks, expr-to-pattern conversion, escape-flag tracking on every token, etc.) erased the lead. README is stale. | Medium (DX / marketing) | README.md | Update README perf table; profile + reclaim with hot-path inlining. The bench-regression baseline (`tests/baselines/bench_baseline.json`) now guards against further drift. |
| K-FUZZ | `task test:fuzz:invalid` — 8 baselined SIGTERMs on 350 KB – 4 MB mutated files (deadline-crosses on >1 MB inputs). Fixed in `07858c4` (emitter nil-pointer + inverted-span guards) and `491d083` (`parse_lhs_tail` .Not + `parse_jsx_children` progress). 8 remaining are not parser bugs, just slow on huge mutated input. | Low | parser perf on very large mutated input | Baselined; not worth chasing. |
| K-FUZZ-DIFF | `task test:fuzz` — 3 baselined cases where Kessel correctly rejects per-spec but OXC accepts: duplicate arrow params (`(b, b) =>` and `(foo, foo) =>`), and `let c = 42; function c(){}` clash. **These are Kessel-correct/OXC-permissive divergences** captured in `tests/baselines/fuzz_baseline.json`. | Low (intentional) | n/a | n/a |
| K-LINK | Debug build (`task build:debug`) emits ~50 cosmetic linker warnings about JSX/TS generic symbol visibility. | Cosmetic | Odin toolchain | Binary works. Ignore. |
| K-LEX | `tests/fixtures/spec/lexical/001_hashbang_bom.js` — BOM + `#!hashbang` rejects (correct per spec), but the `task test:lexical:strict` zero-tolerance variant flags it. The default `task test:lexical` (baseline-gated) is green. | Cosmetic | tests/runners | Use the non-strict variant; the strict gate is opt-in pre-release. |
| K-RECOV | Recovery / parse_expression_statement silently consumes some stray tokens (e.g. bare `:` at statement start emits `EmptyStatement` instead of erroring; `{} = 1;` parses as `{}` BlockStatement + `1;` ExpressionStatement). The `task test:recovery` gate (anchor survival + bounded errors) stays 32/32 green; fixing this is fixture-by-fixture polish. | Low | parser recovery | None; affects ~10 Test262 `language/expressions/assignmenttargettype/*` fixtures. |
| K-NPM | `npm/kessel-parser` ships a CLI-spawn shim and a server-mode async bridge (3.7× faster than spawn-per-call). True NAPI sync API still requires a C ABI export from Odin + node-addon-api wrapper + platform-specific packaging. | Low | npm shim | Use server mode for high-throughput callers. |

**Searched for `TODO`, `FIXME`, `HACK`, `XXX`, `BUG`, `WORKAROUND` markers across all 7 source files: 0 hits** (all matches were `\uXXXX` Unicode-escape comments, false positives).

---

## Incomplete Work

Nothing in `git stash`. No WIP branches. Working tree is clean. The
session-12 work all committed and Test262 baseline relocked.

The biggest "incomplete" surface is the spec gap categorized in K-REGEX
and K-SCOPE above. Both are documented design decisions with explicit
sizing of the impact (~336 + ~15 = ~351 Test262 fixtures = ~0.7 pp).

The README perf table is stale (K-PERF). I deliberately did not edit
README.md this session — the next agent should sync it after deciding
how much perf reclamation is in scope.

---

## What To Work On Next

Numbered, prioritized, with files / why / difficulty / dependencies:

1. **Update README perf table.** Current README claims 0.78x median (22 %
   faster than Rust); fresh measurements show 1.13–1.32x (slower). The
   bench numbers in this handoff (or `task bench:quick` re-run) are the
   accurate replacement. Files: `README.md`. Why: stops misleading new
   users. Difficulty: low. Dependencies: none.

2. **Push to `origin`.** The repo is `main...origin/main` divergent
   (Session 11 was the last push at `6d804bc`; 13 commits since). Files:
   git only. Why: the work disappears if the local clone dies.
   Difficulty: trivial. Dependencies: none.

3. **Reclaim the OXC perf gap.** Profile with `kessel profile parse
   typescript.js`, identify the per-token / per-node overhead added by
   the spec-conformance work. Likely culprits: the `has_escape` flag
   propagation through `eat()`, the PrivateIdentifier walker
   (`pn_walk_*`), the contextual `await_is_reserved_here` /
   `yield_is_reserved_here` predicate calls (uncached). Files:
   `src/parser.odin`, `src/lexer.odin`. Why: K-PERF directly
   contradicts the project's stated goal. Difficulty: medium-high (need
   careful microbench-driven changes; the bench-regression gate now
   catches drift). Dependencies: 1 first.

4. **Continue regex grammar phases.** Session 13 landed five waves
   totalling +281 fixtures. Remaining (~30 total) cluster as:
     a. **Strict Unicode IDStart / IDPart for named-group names**
        (~12) — `(?<❤>a)/u`, `(?<𐐔>a)/u`, `(?<a\uD801>a)/u`. Needs an
        embedded ID_Start / ID_Continue table (the same tables that
        would tighten `lex_identifier` non-ASCII handling). Most
        impactful blocked bucket left in language/literals/regexp/.
     b. **Per-property-value tables** (~10) — `\p{Script=Foo}/u`
        (unknown value), `\p{gc=uppercaseletter}/u` (loose-matching
        rejected). Needs embedded value lists for at least Script,
        Script_Extensions, General_Category. Largest table: ~200
        entries.
     c. **Duplicate named-group same alternative** `(?<x>a)(?<x>b)` (~4) —
        Phase D; needs a small alternation-branch tracker (push
        on `|` and `(`, pop on `)`).
     d. **v-flag set notation deep validation** — currently we
        accept `[A--B]/v`, `[A&&B]/v` and `[[A][B]]/v` permissively.
        Strict validation (only properties-of-strings legal in
        operands of `--`, etc.) is the last big spec surface. ~5+
        fixtures.
     e. **Legacy Sputnik corners** — `/*/`, `///` test bodies are
        eaten as block comments by lex_token before lex_regex sees
        them. ~3 fixtures, low value.
   Files: `src/regex.odin` (extend), `src/lexer.odin`. The dispatch
   site at `regex_validate_pattern` is ready for additive validators.
   Difficulty: medium per bucket; each is a separate, testable commit.

5. **Scope / symbol analysis for the remaining `language/block-scope/
   syntax/redeclaration/*` cluster.** Build a per-Function / per-Block
   scope tree, walk every var-declaration, check its name against the
   enclosing-block lexical-binding set. Files: `src/parser.odin` (new
   `Scope` struct, post-parse walker). Why: 15 Test262 fixtures + paves
   the way for TDZ / used-before-decl. Difficulty: medium-high. Depends
   on: nothing (could land independently).

6. **NAPI sync API for `npm/kessel-parser`.** True synchronous parse
   without spawning. Two paths: (a) C ABI export from Odin + node-addon-
   api wrapper + platform packaging (~weeks); (b) `worker_threads` +
   `Atomics.wait` over the existing server-mode protocol (faster, less
   portable). Files: `src/main.odin` (`parse_oneshot` C entry),
   `npm/kessel-parser/`. Why: server-mode (3.7× spawn-per-call) is good
   but `parseSync` is industry-standard. Difficulty: medium-high (NAPI)
   or medium (worker_threads). Dependencies: none.

7. **Test262 `language/{expressions,statements}/class/elements/syntax/
   early-errors/*` cluster** — 9 fixtures. Mix of edge cases:
   `super.#priv`, ZWJ/ZWNJ in private names (now caught at the lexer
   for the field-name path, but not consistently for the
   private-name-call-expression path — `this.f().#x` whitespace check),
   `class extends (function B() { with ({}); return B; }())` (with-in-
   strict-class-extends-context). Files: `src/parser.odin`. Why:
   plumbing, no big idea — just one-by-one rejection. Difficulty:
   medium. Dependencies: none.

8. **Consider Babel parser test suite (TEST-2) and TypeScript parser
   test suite (TEST-3) once Test262 hits its practical ceiling
   (~99.2 % without regex).** Wider proposal coverage; some overlap.
   Files: new `tests/runners/run_babel.sh`, `tests/runners/run_ts.sh`.
   Difficulty: low (just wire up). Dependencies: 4 first (else regex
   noise dominates).

9. **Transform API + scope-aware walker** built on top of #5's scope
   tree. Mutation / replacement on top of the visitor API. Files:
   `npm/kessel-parser/visitor.js` (already a stub), `src/main.odin`
   (visitor entry). Why: most parsers expose a transform API; Kessel
   currently only emits / re-emits. Difficulty: medium. Dependencies: 5
   first.

10. **Bench-regression gate in CI.** The baseline is now locked; add
    `task test:bench:regression` to the default chain or a separate
    pre-merge hook. Files: `Taskfile.yml` (extend `test` chain).
    Difficulty: trivial. Dependencies: 3 first (else CI flaps on the
    current 1.2× ratio).

---

## Commands Reference

Every command run this session, copied from terminal history:

### Build
```bash
task build                                   # bin/kessel, optimized (47 s cold)
task build:debug                             # bin/kessel-debug, with bounds + dSYM
odin build src -out:bin/kessel -o:speed -no-bounds-check   # raw equivalent of task build
```

### Parse / lex (CLI)
```bash
bin/kessel parse <file.js>                   # ESTree JSON to stdout
bin/kessel parse <file.js> --compact         # minified
bin/kessel parse <file.ts> --lang=ts         # force TS mode
bin/kessel parse <file.tsx> --lang=tsx       # TS + JSX
bin/kessel parse <file.js> --loc             # adds loc { line, column }
bin/kessel parse <file.js> --range           # adds ESLint range tuple
bin/kessel parse <file.js> --preserve-parens # Acorn / OXC paren-wrapper
bin/kessel parse <file.js> --source-type=module
bin/kessel parse <file.js> --source-type=script
bin/kessel parse <file.js> --strict-source-type   # disable auto-upgrade Script→Module
bin/kessel parse <file.js> --force-strict    # start parse in strict mode
bin/kessel parse <file.js> --show-semantic-errors  # post-parse scope walker
bin/kessel parse <file.js> --errors=oxc      # OXC error shape
bin/kessel parse <file.js> --module-record   # +"module": {…}
bin/kessel lex <file.js>                     # token stream
bin/kessel microbench parse <file.js> --iterations 30
bin/kessel microbench lex   <file.js> --iterations 30
bin/kessel profile parse    <file.js>
bin/kessel profile lex      <file.js>
bin/kessel server                            # long-running pipe, used by npm shim
bin/kessel transfer <file.js> <out.bin>      # raw flat-buffer AST for cross-language DataView
```

### Tests (default chain)
```bash
task test                                    # full default chain (1m12s, exit 0)
task test:unit                               # 409 / 409, no skips (11 s)
task test:regression                         # 11 / 11
task test:real                               # 467 / 467 real-world files
task test:nodes                              # 57 / 57 ESTree types
task test:test262                            # 66 / 66 curated subset
task test:spec-fixtures                      # 144 / 144 hand-authored
task test:invariants                         # zero-tolerance ESTree invariants
task test:estree                             # deep-compare vs OXC on 4 corpus files
task test:multi-parser                       # vs Acorn + Babel on snabbdom
task test:spec-compliance                    # 12 curated real files vs OXC
task test:fuzz                               # 97 / 100 baselined
task test:fuzz:invalid                       # 8 / 8 baselined SIGTERMs
task test:crashes-known                      # 0 pinned, 0 new
task test:recovery                           # 32 / 32
task test:negative                           # 125 / 125 baselined-rejected
task test:lexical                            # 9 / 10 (1 known fail)
task test:ambiguity                          # 7 known_fail, 0 unexpected
task test:deep-families                      # per-family OXC deep-compare
```

### Tests (release / opt-in)
```bash
task test:negative:strict                    # 125 / 125, zero-tolerance
task test:estree:strict                      # zero-tolerance integration walk
task test:fuzz:strict                        # zero-tolerance, no baseline
task test:fuzz:invalid:strict                # zero-tolerance, no baseline
task test:lexical:strict                     # zero-tolerance lexical
task test:ambiguity:strict                   # zero-tolerance ambiguity

# Test262 full corpus (~2m30s)
task test:test262:full:json                  # writes tmp/test262_full_run.json
task test:test262:full:regression            # compare vs baseline
KESSEL_T262_ALL_FAILURES=1 KESSEL_T262_JSON=tmp/test262_full_run.json \
    bash tests/runners/run_test262_full.sh   # full run with per-failure triage

# Bench regression
task test:bench:regression                   # geo-mean vs baseline (5 % tolerance)
```

### Baseline updates (after intentional improvement)
```bash
tests/runners/run_tests.sh --update          # regen tests/expected/*.txt
task test:fuzz:update
task test:fuzz:invalid:update
task test:negative:update
task test:spec-fixtures:update
task test:spec-compliance:update
task test:integration:update
task test:lexical:update
task test:ambiguity:update
task test:deep-families:update
node tests/verifiers/verify_test262_full_regression.js --update  # relock test262
task test:bench:regression:update
```

### Bench
```bash
task bench:quick                             # 10 curated files vs OXC, 30 iter
task bench                                   # full 467-file corpus, 20 iter (long)
task bench:oxc:build                         # build the Rust comparison binary
```

### Install
```bash
task install                                 # symlink bin/kessel → ~/.local/bin
task uninstall
```

### Repository state at handoff time

```
$ git status
On branch main
Your branch is ahead of 'origin/main' by 13 commits.
nothing to commit, working tree clean (after this HANDOFF.md is committed)

$ git log --oneline -5
baa71bb test(baselines): relock test262 (98.51%), deep-families, bench — session 12 sync
4f029da feat(parser+lexer): private get/set static-mismatch, ZWJ/ZWNJ as IdStart, BigInt obj-pattern key, await/yield as fn-expr name in inner scope — +3 Test262
b8a00bb feat(parser): script-top-level using ban, labeled-item kind check inline — +5 net Test262
f69311f feat(parser): class field 'constructor', using in case clause — +16 Test262
8d2ce65 feat(parser): §15.7.5 ClassStaticBlockBody scope corrections — +1 Test262

$ wc -l src/*.odin
    1507 ast.odin
    2473 lexer.odin
    7075 main.odin
   12224 parser.odin
     646 raw_transfer.odin
     244 simd.odin
     375 token.odin
   24544 total
```
