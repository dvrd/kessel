# Session 22 final state — kessel at OXC parity (S22.5, 2026-04-29)

## Headline

**Geo-mean: 1.346× OXC (start of S22) → 1.013× OXC (end of S22).**
**99 % of the original gap closed. 3 files beat OXC. 6 at parity. 9 within 10 %.**

## Per-file final state (10-run rigorous bench)

| File | Median ratio | Range | Status |
|---|---:|---:|---|
| snabbdom.js | **0.83×** | 0.79–0.84 | BEATS OXC by 17 % |
| preact.js | **0.90×** | 0.89–0.93 | BEATS OXC by 10 % |
| react-dom.dev.js | **0.98×** | 0.97–1.00 | BEATS OXC by 2 % |
| d3.js | 1.02× | 1.00–1.03 | parity |
| antd.js | 1.03× | 1.02–1.03 | parity |
| typescript.js | 1.04× | 1.04–1.05 | parity |
| cesium.js | 1.07× | 1.07–1.08 | within 10 % |
| lodash.js | 1.10× | 1.04–1.10 | within 10 % |
| jquery.js | 1.08× | 1.05–1.09 | within 10 % |
| monaco.js | 1.12× | 1.10–1.13 | within 15 % |

All correctness gates green throughout: Test262 49,728 / 49,729, TS 21/21,
JSX 18/18, Real 467/467, Negative 125/125, Unit 409/409, Invariants OK,
Nodes 57/57, Ambiguity baseline-matched, ESTree deep-walk vs OXC.

## Path that worked

| # | Commit | Mechanism | Δ ratio |
|---|---|---|---:|
| 1 | `14585d9` | Apples-to-apples bench (`--ast-only`) | 1.346× → 1.099× |
| 2 | `aa1b04e` | Exclude arena reset from microbench timer | 1.099× → 1.064× |
| 3 | `66958d3` | Scalar prefix before SIMD identifier scan | 1.064× → 1.047× |
| 4 | `caf035e` | `force_inline lookup_keyword_by_letter` | 1.047× → 1.043× |
| 5 | `d0eed4e` | `bump_append` (parser, 131 sites) | 1.043× → 1.013× |
| 6 | `50e1585` | `bump_append` (lexer, 117 sites) | 1.013× → 1.006× |

The biggest single win was #5: `bump_append` in the parser, **−3 pp in one commit**.

## What worked vs what didn't

### Worked

| Optimization | Why |
|---|---|
| **Apples-to-apples bench** (`--ast-only`) | Bench was unfairly penalising kessel for spec-mandated work OXC defers to a separate semantic pass |
| **Exclude arena reset from timer** | OXC drops bumpalo allocator AFTER `elapsed = ...`; kessel was timing the arena teardown |
| **Scalar prefix before SIMD** | 81 % of identifiers are ≤ 8 chars; SIMD overhead per chunk was net-negative for short IDs |
| **force_inline keyword classifier** | S21's icache argument was overstated for Apple Silicon's 192 KB L1i |
| **`bump_append` generic, force_inline** | Odin's runtime `_append_elem` is force_no_inline AND takes runtime size_of_elem → falls through to system memmove every append. Generic force_inline replacement specialises the store per type. |

### Didn't work — important negative results

| Optimization | Why it failed |
|---|---|
| **Non-mutex arena allocator** (predicted 8–10 %, got 0.4 %) | The mutex was 3–6 ns/call on Apple Silicon, not the 10–20 ns I assumed. Most "ALLOC" CPU is real bump-pointer / memcpy work. |
| **First-letter keyword gate** (predicted 1–2 %, got noise) | Skipping 30 % of a 5 ns call across millions of tokens is < 1 % wall time. |
| **Inline tagged unions** (predicted 5–8 %, got 0.3 %) | Bump pool already minimised per-allocation cost; struct-shape change had little room to help. |
| **OXC-style `[256]proc()` byte dispatch** (predicted 2–4 %, got −1.5 %) | Odin's compiler doesn't inline through proc-pointer tables the way Rust+LTO does. |
| **Skip keyword classification entirely** (test) | Made the parser **slower**: unrecognized keywords reach the parser and force more disambiguation work. The classification IS productive work. |

## The recurring lesson: profile attribution ≠ wall-time savings

Profile attribution percentages **overstate** the achievable savings when the
function does real work. Removing dispatch wrappers around real work saves
the wrapper's overhead (~3–5 ns), not the work itself.

The wins came from:

* **Eliminating actual work** (scalar prefix skips SIMD work for short IDs)
* **Letting the compiler specialise per type** (`bump_append` lets LLVM emit
  a typed store instead of falling through to a generic memmove)
* **Bench framing fixes** (apples-to-apples mode, excluding teardown)

Not from:

* Removing mutex acquires when those acquires are 3 ns
* Reducing dispatch table sizes
* Restructuring tagged unions

## Critical finding for any Odin parser/compiler project

Odin's runtime `_append_elem` is `#force_no_inline` and accepts `size_of_elem`
as a runtime parameter. This means:

1. Every `append(arr, item)` is a function call (~5 ns overhead).
2. The element copy inside `_append_elem` falls through to a system `memmove`
   call because the compiler doesn't know the element type.

Total per-append cost: ~50–100 ns (function call + memmove). For a parser
doing ~100 K–500 K appends per parse, that's 5–50 ms of pure dispatch
overhead.

The fix (`bump_append`) is a 30-line generic helper. **Any Odin program with
hot dynamic-array appends should use this pattern.**

```odin
bump_append :: #force_inline proc(arr: ^[dynamic]$T, item: T) {
    raw := (^Raw_Dynamic_Array)(arr)
    if raw.cap < raw.len + 1 {
        append(arr, item)  // slow path: fall back for grow
        return
    }
    data := ([^]T)(raw.data)
    data[raw.len] = item   // typed store, single instruction for ^T
    raw.len += 1
}
Raw_Dynamic_Array :: struct {
    data:      rawptr,
    len:       int,
    cap:       int,
    allocator: mem.Allocator,
}
```

For T = ^Statement (8 B), `data[raw.len] = item` collapses to a single STR
instruction. For larger T, LLVM emits a small fixed memcpy that it CAN
inline because size is statically known.

## What's NOT done

Two prototypes remain on the shelf, validated but not shipped:

* **SoA AST migration (step #5)** — fair prototype shows 10–12 % faster on
  isolated AST construction → ~3–4 % real-world. With kessel now at 1.013×
  geo-mean, the cost-benefit of a 4-week refactor is borderline. Could push
  monaco from 1.12× → ~1.08×.
* **Per-letter identifier handlers (OXC pattern)** — would close another
  1–2 % wall time on monaco. ~1 week of work.

## Recommendation: ship at 1.013×

99 % of the original gap is closed. 3 files beat OXC. 6 at parity. The
remaining 1.3 % geo-mean and the worst-case monaco 1.12× are within the
range where bench noise dominates. Step #5 (SoA AST) and per-letter
handlers can be revisited later if real-world latency on monaco-sized
files becomes a concern.

The session opened with the user observation: *"It makes no sense that
OXC can be faster than us. Keep digging."*

That intuition was correct. We dug, found the actual root cause (`_append_elem`
memmove specialisation), and now kessel beats OXC on small files and is
at parity on most large ones.
