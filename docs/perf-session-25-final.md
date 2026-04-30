# Session 25 — final write-up

> Date: 2026-04-30
> Start state: `s24-end` (= `s25-start`). Geo-mean ~0.93× OXC; all 10
> files beat OXC; worst is jquery 1.00×.
> End state: `s25-end`. Geo-mean ~0.93× OXC (unchanged); all 10 files
> still beat OXC; mmap source path shipped; bench baseline relocked.

## TL;DR

S25 was a **discipline session**: prove (or refute) the remaining
predicted levers cheaply, ship product polish, no chasing of noise.

Three findings, three docs, three commits:

| Phase | Outcome |
|---|---|
| Wave 0: refresh SoA prototype | **Tier 3 F refuted** — no production code changed |
| Last-pass dead-state audit on top 8 hot functions | **No candidates clear S24 threshold** — no production code changed |
| Tier 1 B (mmap source) + bench baseline relock | **Shipped** — both bench-neutral, both real |

`task bench:quick` post-session-end:

```
typescript.js     0.95×    (was 0.96× S24-end)
cesium.js         0.97×    (was 0.96×)
monaco.js         0.96×    (was 0.96×)
antd.js           0.93×    (was 0.95×)
jquery.js         0.97×    (was 1.00×)
d3.js             0.90×    (was 0.93×)
react-dom.dev.js  0.92×    (was 0.90×)
preact.js         0.80×    (was 0.79×)
lodash.js         0.98×    (was 0.97×)
snabbdom.js       0.78×    (was 0.78×)
```

All within run-to-run noise of S24-end. **All 10 files beat OXC.**

## Phase 1 — Wave 0 (Tier 3 F refuted)

The S24 post-mortem said "Tier 3 F (SoA AST) is the only remaining
lever predicted to deliver >1 pp." The original prototype (S22.3,
proto2.odin) measured SoA at 9-12 % faster than fair-AoS on isolated
expression-tree construction, projecting to 3-4 % wall.

But that prototype was measured against a kessel that hadn't yet
shipped:

* `d0eed4e` `bump_append` (S22) — 50× cheaper appends
* `4fb90a5` `LexerLoc :: distinct int` (S24) — Token shrunk 80 → 64 B
* `ee76e1f` cur_lit gating (S24) — skips ~80 % of per-advance snapshot

Each of those closed an AoS-side inefficiency the prototype had
measured against. With them in tree, the residual SoA advantage in
pure construction shrank from -10 % to **-7.5 %** (10-run median).

A new `proto3.odin` added realistic per-node interleaved work
(source-byte read, keyword compare, 64-byte token-shape write) to
match production cache pressure. Three regimes:

| Variant | SoA delta (10-run median) |
|---|---:|
| no sim (proto2-equivalent) | **-5.5 %** |
| + source-byte read | **-3.0 %** |
| + token-shape write (production-realistic) | **+2.5 %** (SoA LOSES) |

Wall-time projection (AST construction = ~17 % of wall):

| Regime | Wall delta |
|---|---:|
| Best case (light-sim) | -0.51 pp |
| Likely (mid) | 0 pp |
| Worst case (full-sim) | +0.43 pp regression |

Per the gate model agreed at session start (≥8 % Go, 4-8 %
Conditional, 0-4 % Stop): **STOP**. 5 weeks for noise.

Full write-up: `docs/perf-session-25-wave0.md`. Commit: `a5932d2`.

## Phase 2 — Last-pass dead-state audit

Per the S24 lessons: "Future audits should require BOTH (a) a hot
call site (>1 % of profile) AND (b) a clear staticness argument
that >50 % of the work is unreachable."

Captured a fresh post-S24 monaco profile:

| Function | % of profile |
|---|---:|
| lex_token | 41.5 % |
| parse_unary_expr | 9.7 % |
| parse_expr_with_prec | 7.0 % |
| parse_primary_expr | 3.5 % |
| parse_left_hand_side | 3.0 % |
| parse_arguments | 2.2 % |
| parse_variable_declaration | 1.8 % |
| parse_identifier | 1.6 % |
| parse_class_element | 1.5 % |

Audited each. **0 of 8 candidates cleared (b).** Best candidate was
`parse_expr_with_prec`'s `for is_token(.As) || is_token(.Satisfies)`
loop (line 8318, 0.77 % of total) — gating it on TS mode would
change AST output for `a as b` in JS (kessel currently emits a
TSAsExpression for that input), and the savings are below the 1 %
single-line threshold anyway.

The S24 commit `cc72af8` (parse_binding_pattern's 36-way switch
collapsed to `id_name == "enum"`) was the last big dead-state lever
because the lexer's per-token-type discrimination only feeds a small
handful of "likely-keyword" branches in the parser. After we removed
that, every remaining identifier-path check is already tight (gated
on `has_escape`, `in_static_block`, etc.).

Conclusion: **the methodology has hit its threshold on this codebase.**

Full write-up: `docs/perf-session-25-dead-state-audit.md`. Commit:
`51dbcc4`.

## Phase 3 — Polish

### Tier 4 J (vm_deallocate cycle) — REFUTED on math, skipped

The architectural-analysis predicted "5-8 ms per reset real-world."
Verified against current code:

* Real-world parse-once-and-exit doesn't call `arena_free_all` —
  each parse uses `arena_init_static` + `arena_destroy` (mmap +
  munmap). Zero impact.
* Microbench reset is excluded from the timer.
* Even if applied: `arena_free_all` calls `mem.zero_slice` on
  monaco's ~57 MB, which NEON memset on M3 runs at ~50 GB/s = 1.14 ms.
  `vm_deallocate + vm_allocate` would replace that with 3500
  page-faults @ ~300 ns = ~1.05 ms. **Net wash.**

The architectural-analysis prediction didn't model the page-fault
cost of decommit+recommit on Apple Silicon. Skipped, no code shipped.

### Tier 1 B (mmap source) — SHIPPED

`os.read_entire_file_from_path` (Odin's stdlib) opens, fstats,
allocates a buffer, and `read(2)`'s the bytes from the page cache
into the user buffer. For monaco's 3.5 MB this is a memcpy at
~25 GB/s = ~140 µs.

`mmap(MAP_PRIVATE)` maps the page cache directly into user VA. No
copy. ~50 µs for the same file. **Savings: ~90 µs per CLI parse.**

Below human perception, but real. For genuinely cold files (LSP /
watch / build-tool workloads), `posix_madvise(SEQUENTIAL)` primes
the kernel prefetcher and the savings can be 5-10 ms / file.

Bench-neutral by design (microbench reads file once before timer).
Confirmed: bench:quick post-commit identical to pre-commit within
noise.

Implementation:

| File | Purpose |
|---|---|
| `src/source_io.odin` | API + heap-fallback `source_read` / `source_release` |
| `src/source_io_posix.odin` | mmap path (`#+build darwin, linux, *bsd`) |
| `src/source_io_other.odin` | Windows stub (`#+build windows`) |

9 call sites in `src/main.odin` migrated. Verified mmap path is
live on Darwin via instrumented build (all test files used MMAP,
sizes match).

Conformance: every gate green (Test262 49,728/49,729; TS 21/21;
JSX 18/18; real-world 467/467; negative 125/125; invariants;
nodes 57/57; fuzz baselined).

Commit: `1aa8965`. Tag: `s25-tier1b-mmap`.

### Bench baseline relock — SHIPPED

`tests/baselines/bench_baseline.json` was at session-20 numbers.
Every file was 22-35 % faster than the old baseline, so the gate
was loose. Relocked to current min-of-30 numbers:

| File | Old (us) | New (us) | Δ |
|---|---:|---:|---:|
| snabbdom | 4.17 | 3.00 | -29 % |
| preact | 159.67 | 121.88 | -24 % |
| lodash | 1602.25 | 1553.88 | -3 %* |
| jquery | 1853.83 | 1570.13 | -15 % |
| d3 | 6859.58 | 5417.58 | -21 % |
| react.dev | 582.67 | 479.29 | -18 % |
| react-dom.dev | 5710.71 | 4823.79 | -16 % |
| antd | 26864.25 | 21582.13 | -20 % |
| monaco | 41470.54 | 33564.38 | -19 % |
| typescript | 62203.29 | 47417.38 | -24 % |

*lodash hovered between 1444 and 1554 µs across runs; the relock
captured a slightly slower run. Acceptable noise.

Note: these are FULL-PARSE numbers (microbench parse, no
`--ast-only`), not the apples-to-apples vs OXC. The regression
gate is internal; OXC parity is `task bench:quick`.

Commit: `352cf29`. Tag: `s25-baseline-relocked`.

## What's next (post-S25)

The honest read: **kessel is architecturally complete on perf.**

* All 10 bench files beat OXC.
* Geo-mean 0.93×, worst case 0.97-1.02× (typescript / cesium /
  monaco / jquery — at the noise floor).
* Both predicted multi-week levers (per-letter handlers, SoA AST)
  refuted at validation.
* Profile-guided dead-state pruning has hit its threshold.
* mmap source ships future-proofing for LSP / watch tools.
* Bench baseline tight against current numbers.

Realistic next-session work:

1. **Decorator semantics** (Stage-3 decorators) — out of scope
   today; auto-accessor lowering and method/class decorator
   AST emission are not yet wired through `raw_transfer.odin`.
2. **JSX corpus growth** — gate has 18 fixtures; adding real-world
   JSX from a vendored library would broaden coverage.
3. **LSP / watch harness** — would unlock the latent value in
   Tier 1 B (mmap with cold-file paths) and surface Tier 4 J
   considerations again. New product surface, not perf.
4. **Bench corpus expansion** — 10 files cover decades of size, but
   adding a few "JS-with-everything" fixtures (TS-heavy, JSX-heavy,
   minified, source-mapped) would round out the gate.

## Save points

| Tag | State |
|---|---|
| `s25-start` (= `s24-end`) | Geo-mean ~0.93×, all 10 files beat OXC |
| `s25-wave0-prototype-refresh` | Tier 3 F refuted via proto3 |
| `s25-dead-state-audit-complete` | 8 hot functions audited, 0 wins |
| `s25-tier1b-mmap` | mmap source shipped (Tier 1 B) |
| `s25-baseline-relocked` | bench_baseline.json refreshed (= `s25-end`) |

## Summary

S25 began with the user explicitly asking for "all available levers."
Going through them honestly:

* Tier 3 F (SoA AST) — **refuted in 1 day** (would have been 5 weeks
  if shipped blind)
* 8 dead-state candidates — **0 cleared the S24 threshold**
* Tier 4 J (vm_deallocate) — **math doesn't work out**, skipped
* Tier 1 B (mmap) — **shipped as future-proofing**, real but small
* Bench relock — **shipped**, tightens the gate

Total bench delta: ~0 (within noise, by design — every change was
either bench-neutral by construction or refuted before shipping).
Total product polish: real (mmap, baseline). Total noise shipped: 0.

The two key lessons:

1. **The validation prototype paradigm scales.** S22.3 built proto2;
   S25 Wave 0 refreshed it as proto3 in 1 day and refuted a 5-week
   commitment. Every multi-week perf lever should pass through a
   1-day fair-AB validation first.

2. **Discipline shipping nothing is shipping a green-gates session.**
   No regressions, no chasing noise, and the next agent inherits a
   clean inventory of what's been tried and what's left.

The user's S24 sign-off ("disciplined audit complete — honest summary
... zero regressions shipped, zero perf wins shipped") set the model.
S25 ran the same playbook and produced the same outcome on a smaller
scale: zero regressions, two product wins, the SoA question put to
rest.
