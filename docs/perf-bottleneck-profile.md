# Deep-profile bottleneck analysis (S22.2, 2026-04-29)

> Sampling profile of kessel `--ast-only` parse vs OXC parser-only on
> typescript.js / monaco.js / cesium.js / antd.js. 4× 200-iteration
> microbench runs, ~4,500 samples each (≥ 20K samples total per
> aggregate). Tool: macOS `sample` (1 ms intervals).

## Executive summary

The remaining 6 % geo-mean gap to OXC has **two structural causes**:

1. **Allocator vtable + mutex overhead: ~10 % of CPU (vs 0.2 % in OXC)**
   `mem.virtual.arena_allocator_proc` in Odin's stdlib calls
   `sync.mutex_guard` on **every** allocation (alloc / resize / free_all).
   Even uncontended on a single-threaded parse, that's a serialised
   atomic acquire+release per call. With millions of dynamic-array
   appends and AST-fallback allocations, this adds ~10 % wall-time.
   **OXC's bumpalo has zero allocator dispatch and zero mutex.** This is
   THE single-biggest contributor to the remaining gap.

2. **`lex_token` + `lex_identifier` (inlined) + `lookup_keyword_by_letter`:
   42 % of CPU (vs ~32 % in OXC, ~10 pp gap)**
   The body of `lex_identifier` (UTF-8 decode + SIMD `simd_scan_id_cont`
   + `lookup_keyword_by_letter` chain of byte-compares) is doing the
   right work but ~30 % more of it per token than OXC's per-letter
   handler `byte_handlers::ID_T` + `byte_handlers::L_T`. The keyword
   classifier is not yet at the structural minimum.

Other categories are at-or-below OXC parity:
* `parse_*` total: 42 % vs OXC's 49 % (kessel does **less** parse work)
* `string_eq`: 2.3 % (small, related to property-name compares)
* JSON output, file I/O: not in `--ast-only` bench path

## Aggregate hotspot table (4-file average)

| Rank | Function | ts | mon | ces | antd | avg | Cat |
|---:|---|---:|---:|---:|---:|---:|:---:|
|  1 | `main::lex_token` | 35.1 % | 29.4 % | 28.4 % | 32.0 % | **31.2 %** | LEX |
|  2 | `main::lookup_keyword_by_letter` | 11.5 % | 10.9 % | 10.7 % | 12.2 % | **11.3 %** | LEX |
|  3 | `main::parse_unary_expr` | 10.5 % |  9.3 % | 10.8 % |  9.4 % | **10.0 %** | PARSE |
|  4 | `main::parse_expr_with_prec` |  4.9 % |  6.2 % |  7.8 % |  4.9 % |  6.0 % | PARSE |
|  5 | `main::parse_binding_pattern` |  4.0 % |  4.1 % |  4.8 % |  3.7 % |  4.1 % | PARSE |
|  6 | `main::parse_primary_expr` |  2.3 % |  4.0 % |  2.3 % |  3.3 % |  3.0 % | PARSE |
|  7 | `main::parse_arguments` |  2.8 % |  2.5 % |  3.2 % |  2.4 % |  2.7 % | PARSE |
|  8 | `main::parse_variable_declaration` |  1.7 % |  2.0 % |  3.0 % |  2.7 % |  2.4 % | PARSE |
|  9 | `runtime::string_eq` |  2.8 % |  2.0 % |  1.7 % |  2.7 % |  2.3 % | STR |
| 10 | **`runtime::_append_elem`** |  2.1 % |  2.0 % |  2.3 % |  1.8 % | **2.1 %** | **ALLOC** |
| 11 | `main::parse_left_hand_side_expr` |  1.1 % |  3.6 % |  1.7 % |  1.7 % |  2.0 % | PARSE |
| 12 | `main::parse_statement_or_declaration` |  3.4 % |  1.5 % |  1.5 % |  1.7 % |  2.0 % | PARSE |
| 13 | `main::lex_string` |  1.3 % |  1.6 % |  2.5 % |  2.4 % |  2.0 % | LEX |
| 14 | **`mem_virtual::arena_allocator_proc`** |  1.5 % |  2.7 % |  1.6 % |  1.4 % | **1.8 %** | **ALLOC** |
| 15 | `main::parse_identifier` |  1.1 % |  2.1 % |  1.9 % |  0.9 % |  1.5 % | PARSE |
| 16 | **`mem_virtual::arena_alloc_unguarded`** |  1.4 % |  1.9 % |  1.0 % |  1.1 % | **1.4 %** | **ALLOC** |
| 17 | **`mem_virtual::alloc_from_memory_block`** |  1.2 % |  1.6 % |  1.1 % |  1.0 % | **1.2 %** | **ALLOC** |
| 18 | `main::parse_function_body` |  1.5 % |  1.1 % |  0.8 % |  0.9 % |  1.1 % | PARSE |
| 19 | `main::parse_object_expr` |  0.6 % |  0.6 % |  1.1 % |  1.8 % |  1.0 % | PARSE |
| 20 | `main::parse_property` |  0.8 % |  0.4 % |  0.7 % |  1.9 % |  1.0 % | PARSE |

## Categorical breakdown (kessel monaco --ast-only vs OXC monaco)

| Category | Kessel | OXC | Δ |
|---|---:|---:|---:|
| **LEX** (lex_token + identifier + keyword + string) | 42.8 % | ~32 % | **+11 pp** |
| **PARSE** (parse_*) | 42.7 % | 49.8 % | **−7 pp** |
| **ALLOC** (arena dispatch + array growth) | **10.0 %** | **0.2 %** | **+9.8 pp** |
| STR (string_eq) | 2.0 % | (rolled in) | — |
| OTHER | 2.5 % | (rolled in) | — |

PARSE being LOWER in kessel and ALLOC + LEX being HIGHER means: kessel
*completes the parse work faster than OXC* but pays 17 pp more in
infrastructure (alloc + lex). Closing the alloc gap puts us at OXC ratio
~0.97× ; closing the lex gap puts us beating OXC outright.

## Detail: ALLOC breakdown (kessel monaco)

| Function | self-time | What it does |
|---|---:|---|
| `mem_virtual::arena_allocator_proc` | 2.72 % | Vtable dispatch + mode switch |
| `runtime::_append_elem` | 2.03 % | `[dynamic]T` append helper |
| `mem_virtual::arena_alloc_unguarded` | 1.90 % | Bump after mutex |
| `mem_virtual::alloc_from_memory_block` | 1.57 % | Block-local bump |
| `runtime::mem_alloc_bytes` | 1.21 % | High-level alloc dispatch |
| `runtime::_mem_resize` | 0.48 % | Dynamic-array growth |
| `runtime::_reserve_dynamic_array` | 0.42 % | Initial reserve |
| `DYLD-STUB$$memcpy` | 0.27 % | Element copy in append |
| **Total** | **10.9 %** | |

### The mutex

```
// Odin core/mem/virtual/arena.odin line 110
arena_alloc :: proc(arena: ^Arena, size: uint, ...) -> ([]byte, Allocator_Error) {
    ...
    sync.mutex_guard(&arena.mutex)            // ← acquired on every alloc
    return arena_alloc_unguarded(arena, size, alignment, loc)
}

// Same file, line 360 (the .Resize path used by [dynamic]T grow)
case .Resize, .Resize_Non_Zeroed:
    ...
    sync.mutex_guard(&arena.mutex)            // ← acquired on every grow
    ...
```

`sync.mutex_guard` is a defer-scope guard that does an atomic acquire
on enter and atomic release on exit. Even uncontended, that's
~10–20 ns per call on Apple Silicon (LDAXR / STLXR loop on the futex word).

For ~5 million dynamic-array appends + AST allocations across a parse
of monaco, that's ~50–100 ms of pure mutex overhead — the entire 10 %
of the parse budget.

## Detail: LEX breakdown — where lex_token's 31 % goes

`lex_token` itself is `#force_no_inline` for the body but inlines its
hot helpers (`lex_identifier`, `lex_plus`, etc.). Line-attribution
samples on monaco show the time distribution:

| Source line | Samples | What's there |
|---:|---:|---|
| 800 | 845 | `return lex_identifier(l, start, flags)` (inlined body) |
| 590 | 184 | Annex B HTML-comment slow-path scanner |
| (epilogue) | 160 | function exit / trampoline |
| 799 | 152 | `if is_id_start_fast(c) {` |
| 782 | 143 | `if tt != .Invalid {` (single-char check) |
| 550 | 91 | function entry / register loads |
| 779 | 72 | `tt := single_char_tokens[c]` |
| 812 | 51 | escape-identifier check `\u…` |
| 806 | 43 | id-branch close |
| 816 | 39 | number check `c >= '0' && c <= '9'` |
| 840 | 36 | operator switch entry |
| 764 | 31 | `l.offset = off` writeback |

Of the 1,406 lex_token samples on monaco, **845 (60 %) are inside the
inlined `lex_identifier` body**. The actual `lex_token` framing /
dispatch is ~12 % of CPU; `lex_identifier` is ~18 % of CPU.

Breaking down `lex_identifier`'s 18 %:
* SIMD `simd_scan_id_cont` body — productive work, hard to optimise further
* `lookup_keyword_by_letter` call (separate 11.3 % bucket on the table above)
* UTF-8 width decode for the first byte
* Optional `lex_validate_unicode_identifier` for non-ASCII (rare)

The two attackable elements are:
* **`lookup_keyword_by_letter` first-letter gate from the caller**:
  the function already returns `.Identifier` for length < 2 / > 10 and
  for non-`a..z` first byte, but the call still happens (it's
  `#force_no_inline`). Gating the call from `lex_identifier` with
  `if length >= 2 && length <= 10 && first >= 'a' && first <= 'z'` would
  skip the call+return for ~30 % of identifiers.
* **Per-letter compare chain → SIMD compare**: every keyword candidate
  is compared byte-by-byte. NEON 8-byte compares would fold each
  candidate to one instruction, but the dispatch logic (which keyword
  to compare against) still needs the per-letter / per-length switch.

## Detail: parser-side `[dynamic]T` hotspots

`_append_elem` is 2.0 % of CPU — about 100K append calls. Top fields by
append-site count in `parser.odin`:

| Field | Sites | Notes |
|---|---:|---|
| `p.errors` | 25 | Error reporting |
| `obj.properties` | 8 | Object expressions / patterns |
| `tmpl.quasis` | 4 | Template literals |
| `m.items` | 4 | Module entries |
| `arr.elements` | 3 | Array literals |
| `p.scope_pending` | 3 | Scope queue |
| `seq.expressions` | 2 | Sequence expressions |
| `body.body` | 2 | Block / function bodies |

Most of these are in the **hot path of parsing**: every block, every
call, every object literal. Pre-allocating capacity where the upper
bound is known (e.g., function params count after `(...)` peek) removes
the growth path entirely.

## Comparison: OXC's hottest functions on monaco

```
  1. identifier_name_handler         9.7 %  (LEX, byte_handlers::ID_T body)
  2. parse_member_expression_rest    9.2 %  (PARSE)
  3. cursor::advance                 7.6 %  (LEX cursor)
  4. parse_binary_expression_…       5.6 %  (PARSE)
  5. parse_lhs_expression_…          4.7 %  (PARSE)
  6. parse_primary_expression        4.4 %  (PARSE)
  7. parse_assignment_expression_…   4.3 %  (PARSE)
  8. lexer::string::get_string       3.1 %  (LEX, string body)
  9. parse_identifier_expression     2.8 %  (PARSE)
 10. ident_hasher::ident_hash        2.6 %  (interning hash)
 11. byte_handlers::ID_T            2.3 %  (LEX dispatch entry)
 12. parse_identifier_name           2.0 %  (PARSE)
 13. byte_handlers::L_T              1.7 %  (LEX 't' letter)
 14. byte_handlers::PRD              1.6 %  (LEX period)
 15. byte_handlers::PNC              1.5 %  (LEX paren close)
```

Note: OXC's per-byte handlers (ID_T, L_T, PRD, PNC, EQL, COM, QOD, …)
add up to 11.5 % of CPU. Plus the dispatched-to bodies
(`identifier_name_handler` 9.7 %, `get_string` 3.1 %), `cursor::advance`
7.6 %, etc. Total LEX is ~32 %.

## What this analysis rules in / out

### In (high-confidence wins, ordered by ROI)

**Note (S22.2 follow-up): Two predicted wins from the original analysis
were implemented and measured — both underperformed dramatically.
Profile attribution percentages do NOT linearly map to wall-time savings.**

1. **Non-mutex single-threaded arena allocator** — ATTEMPTED, REVERTED
   * Predicted: 8–10 % wall time. Measured: ~0.4 % (within noise).
   * Implementation: clean copy of `arena_allocator_proc` with
     `sync.mutex_guard` removed and `arena_alloc_unguarded` body
     inlined. Replaced 14 call sites in `main.odin`. All gates green.
   * Why prediction was wrong: on Apple Silicon, Odin's
     `sync.mutex_guard` compiles to two atomic exchanges (acquire +
     release) which take ~1–3 ns each. Total mutex overhead is
     ~3–6 ns per call — not the 10–20 ns I assumed. The rest of
     the "10 % ALLOC" attribution is real work (bump pointer, cap
     check, memcpy) that doesn't disappear by removing dispatch.
   * Profile after the change: `kessel_arena_allocator_proc` 1.6 % +
     `fast_arena_alloc` 2.3 % = 3.9 % (vs old 4.6 %). Saved ~0.7 pp
     of profile attribution but not of wall time.

2. **First-letter gate before `lookup_keyword_by_letter`** — ATTEMPTED, REVERTED
   * Predicted: 1–2 %. Measured: within ±1 % noise.
   * Implementation: moved the `length ∈ [2,10]` and
     `first ∈ [a..z]` checks from inside the no-inline callee up to
     `lex_identifier`. All gates green.
   * Why prediction was wrong: ~70 % of real identifiers ARE in the
     gate's accepted range (lowercase, 2–10 chars). The gate skips
     ~30 % of calls, but each skipped call+return costs only ~3–5 ns.
     Skipping 30 % of a 5 ns op across the file is < 1 % of parse.

### The lesson: profile %s overstate the achievable savings

When a function shows up at X % of CPU, only the *dispatch + bookkeeping*
portion of those cycles is removable by call-graph restructuring. The
*actual computational work* (bump pointer, memcpy, comparison) is
irreducible at this level. To save real wall time, we have to eliminate
the WORK, not just the wrapping. Levers that eliminate work:

* Pre-sizing dynamic arrays (no growth = no realloc + memcpy)
* Flat buffers instead of dynamic arrays (no per-element bookkeeping)
* Indices instead of pointers (smaller AST = fewer cache misses)
* Single-pass tokenize-and-emit (no intermediate token storage)

These are all step #5 (full DoD migration). It is now the only remaining
structural lever with a credible double-digit gain.

### Revised predicted ROI table (post-measurement)

| # | Lever | Predicted | Measured | Verdict |
|---|---|---:|---:|---|
| 1 | Non-mutex arena | 8–10 % | 0.4 % | reverted |
| 2 | Keyword first-letter gate | 1–2 % | noise | reverted |
| 3 | Pre-allocate dynamic-array capacity | 1–2 % | not tried | unlikely > 1 % given #1+#2 |
| 4 | OXC-style proc-ptr byte dispatch | 2–4 % | −1.5 % (Apr 2026) | dead |
| 5 | Inline tagged unions (step #3) | 5–8 % | 0.3 % geo / 5 % monaco | reverted |
| 6 | **Full DoD/SoA migration (step #5)** | **12 %** | **not tried** | **the real lever** |

Four of the five "quick wins" came in 5–10× smaller than predicted.
The remaining 6 % gap to OXC requires structural change, not
dispatch-layer surgery.

### Out (proven low-or-no-gain, do not retry)

* **OXC-style `[256]proc()` byte dispatch table** — already tested April 2026
  (commits `02da77c`, `f815e90`). +1.5 % slower on proc-pointer variant;
  0 % change on action-enum variant (LLVM already produces this code from
  the source switch). Odin's compiler doesn't inline through proc-ptr
  tables the way Rust+LLVM with LTO does.
* **Inline tagged unions (step #3)** — already attempted S22.1 (2026-04-29).
  −5 % on monaco only, −1 % (noise) on every other file. AST allocs dropped
  36 % but cost was sub-1 % geo-mean for ~3–5 hours of test infrastructure
  churn. Reverted; details in `perf-deep-analysis.md`.

### Maybe (worth experimenting, lower confidence)

* **SIMD keyword comparison** in `lookup_keyword_by_letter`. Compare
  8 bytes against canonical keyword in one NEON instruction. Could
  trim 2–4 % from the 11.3 % keyword classifier budget. Risk: the
  per-length / per-letter dispatch still costs whatever it costs;
  only the comparison itself shrinks.
* **Length-then-letter switch reorder** in the keyword classifier.
  Tested in S22 with mixed results (variant tested was reverted). The
  current per-letter-then-length structure is reasonable.

## The arithmetic of closing the gap (REVISED post-S22.2)

Current state: **kessel 1.064× OXC geo-mean (1.20× monaco worst)**.

The original projection assumed every dispatch-overhead percentage
would convert 1:1 into wall time when removed. After measuring two of
those levers, both came back 5–10× smaller than predicted because the
attributed cycles were doing irreducible work, not just bookkeeping.

**Updated projection: dispatch-layer micro-optimisation can deliver at
most ~1–2 % combined. The remaining ~5 % gap requires eliminating
the WORK itself — step #5 (full DoD/SoA migration) or it doesn't happen.**

Step #5 best-case (12 % at predicted strength):

```
1.064 × (1 - 0.10) ≈ 0.96   geo-mean (kessel BEATS OXC by ~4 %)
1.20  × (1 - 0.12) ≈ 1.06   monaco within 6 %
1.17  × (1 - 0.12) ≈ 1.03   cesium at parity
```

Step #5 pessimistic (5× less than predicted, in line with #1–#3 results):

```
1.064 × (1 - 0.025) ≈ 1.04   geo-mean (still good enough to ship)
```

Either way, step #5 is the only honest path. Dispatch-layer
optimisation has been exhausted.
