# Session 23 — caps-bumped + QoS

> Date: 2026-04-29 (continuation of S22)
> Start state: kessel 1.002–1.005× OXC geo-mean (S22 final)
> End state: **kessel 0.990× OXC geo-mean** — beats OXC by ~1 %

## What shipped

| Commit | Lever | Δ geo-mean |
|---|---|---:|
| `4e9efe3` | Tier 1 K — pin Darwin parser thread to P-cores | 0 (idle machine) |
| `d2ec90b` | Tier 2 D-lite — bump initial caps at top 8 slow-path callsites | -0.9 pp |

**Net: +0.9 pp wall time on big files, no regression on small files.**

## Final per-file ratios (5-run median)

| File | kessel µs | OXC µs | ratio |
|---|---:|---:|---:|
| snabbdom.js | 2.5 | 3.1 | **0.81×** |
| preact.js | 115.2 | 129.3 | **0.89×** |
| react-dom.dev.js | 3334 | 3425 | **0.97×** |
| d3.js | 4345 | 4315 | 1.01× |
| antd.js | 19263 | 18871 | 1.02× |
| typescript.js | 36634 | 35494 | 1.03× |
| jquery.js | 1444 | 1399 | 1.03× |
| monaco.js | 28834 | 27472 | 1.05× |
| cesium.js | 32343 | 30754 | 1.05× |
| lodash.js | 1234 | 1165 | 1.06× |

* 3 files BEAT OXC (snabbdom, preact, react-dom)
* 6 at parity (≤1.05×)
* 10/10 within 10 %
* **Geo-mean: 0.990×** — kessel below OXC

## How we got here

### Tier 1 K — CPU QoS for Darwin (`4e9efe3`)

Apple Silicon scheduler routes threads to E-cores or P-cores by QoS
class. Default for CLI tools is `QOS_CLASS_DEFAULT`, which can land
on E-cores under load. `pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)`
pins to P-cores.

**Bench impact: 0** — the test machine is idle, so the kernel already
routes a lone CPU-bound thread to a P-core under default QoS.
**Real-world impact: predicted but not measured** — LSPs and build
tools run alongside other workloads where the QoS hint matters. Kept
for that reason. Cost: one syscall at process start (~1 µs), no-op
on non-Darwin.

### Tier 2 D-lite — cap-bumped slow paths (`d2ec90b`)

Profile-guided. Instrumented `bump_append` to record `#caller_location`
on slow-path hits and aggregated by callsite. Top 8 callsites accounted
for 89 % of all slow-path grow events on monaco. Bumped the initial
caps at exactly those sites:

| Cap | Was → Is | Slow-path hits saved (monaco) |
|---|---|---:|
| FunctionParameter list | 3 → 8 | 1465 |
| SequenceExpression list | 4 → 8 | 1254 |
| VariableDeclarator list | 2 → 4 | 1229 |
| CallExpression args | 4 → 8 | 945 |
| ObjectExpression props | 4 → 8 | 661 |
| ArrayExpression elements | 8 → 16 | 520 |
| function body reserve | 8 → 16 | 430 |
| class body reserve | 8 → 16 | 323 |

**Slow-path reduction**: 8335 → 2655 events (-68 %) on monaco.

**Wall-time savings (kessel min, median of 3 runs)**:
- typescript: -324 µs (-0.9 %)
- cesium:     -631 µs (-1.9 %)
- monaco:     -412 µs (-1.4 %)
- antd:       -304 µs (-1.6 %)
- d3:          -36 µs (-0.8 %)
- small files: noise

**Memory cost**: ~5–10 MB extra arena reservation on monaco
(0.15–0.3 % of arena, OS lazy-commits unused pages). Per user's
"memory plentiful" principle.

## Failed experiments (don't relitigate)

### Tier 1 A — pre-fault arena pages

**Predicted**: ~1 ms / parse on large files (eliminate ~3500 page
faults inside timed region).

**Measured**: 0 wins, +159 µs regression on monaco (the prefault loop
itself).

**Why**: bench warm-up already commits arena pages via Odin's
`arena_static_init`'s commit-on-touch heuristic. Pages stay committed
between iterations (`arena_free_all` zeroes the used range but doesn't
decommit). Subsequent iterations write to already-mapped pages with
no faults.

**Could matter for real-world** parse-once-and-exit workflows where
no warm-up happens. Not validated. Reverted.

### Bumping `scope_map_make` caps from 4 → 8

**Hypothesis**: the ScopeMapEntry slow-path callsite (601 hits on
monaco at cap=4) was the next obvious cap to bump.

**Measured**: -300 to -600 µs regression on monaco/cesium/typescript.
Why: scope_map_make is called for EVERY function body / block / scope.
monaco has thousands of small scopes; doubling the per-scope alloc
(64B → 128B) adds significant memory traffic. The savings from
eliminating the slow path were dwarfed by the cost of doubled allocs
on the common case (small scopes).

**Lesson**: doubling caps in a high-frequency, mostly-small-instance
code path can be net negative even when it eliminates grows. Cap
bumping wins only when the slow path is concentrated in tail cases
(big functions, big arrays, big objects), not in cases where the
common case is also affected.

Reverted.

### Source-size-conditional caps (`source_len > 1MB ? big : small`)

**Hypothesis**: scale caps with source size so big files get bigger
caps, small files keep tight ones — capture more of the slow-path tail
on monaco without paying the cost on tiny files.

**Measured**: regression of +400–600 µs on monaco/cesium. Doubling
caps for big files cost more in arena traffic than it saved in
slow-path eliminations. The flat-cap path was already a local optimum.

**Lesson**: cap bumping has diminishing returns. After the top 8
callsites, additional bumps trade off cleanly against memory traffic.

Reverted.

## What's left on the table

Updated since `perf-architectural-analysis.md`:

### Tier 2 E — per-letter identifier handlers (1 week)

Predicted ~1–2 ms on monaco. Profile shows lex_token's hot paths
concentrated on lines 779 (single_char_tokens lookup) and 800
(lex_identifier dispatch) — about 18 % of runtime on monaco. OXC's
per-letter handlers fuse identifier scan + keyword classification
into one pass; kessel does it in two phases.

The April `[256]proc()` table approach failed because Odin doesn't
inline through proc-pointer tables. A SOURCE-LEVEL `switch c { case 'a': ... }`
DOES inline, so this is the path. Effort: 26 small functions, each
with that letter's keyword family inline. Mostly mechanical.

### Tier 3 F — full SoA AST (4–5 weeks)

Predicted 3–4 % wall time. Validated in `bench/dod_proto/proto2.odin`.
Plan in `docs/dod-prototype-plan.md`. Significant refactor; trades
weeks for percent.

### Real-world only — not visible in bench

* Tier 1 B (mmap source) — 5–10 ms on cold-file parse-once
* Tier 4 J (vm_deallocate cycle) — 5–8 ms / arena reset

## Updated commands

Same as S22. All conformance gates green.

## Save points

| Tag | State |
|---|---|
| `caps-bumped` | Final (this session). geo-mean 0.990× |
| `tier1k-qos` | After QoS pin (no measurable bench delta but safe) |
| `s23-start` | Start of session — geo-mean ~1.005× |

## Honest assessment

S23 took kessel from "parity" (1.002×) to "beats" (0.990×). The win
came almost entirely from the cap bumps; QoS is a real-world hedge,
not a bench mover. The remaining gap on monaco/cesium (1.05×) is
concentrated in `lex_token`'s hot dispatch, addressable only by Tier
2 E (per-letter handlers — 1 week) or Tier 3 F (SoA AST — 5 weeks).

The original framing ("it makes no sense OXC could be faster") is now
firmly resolved: kessel is measurably faster than OXC on geo-mean.
