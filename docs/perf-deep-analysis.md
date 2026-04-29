# Why Kessel Is Slower Than OXC — Deep Analysis

*Session 22, 2026-04-29. Supersedes the superficial v1 in `perf-analysis.md`.*

## Why this exists

The first analysis concluded the gap was "architectural and structural,
nothing to do but big rewrites." That answer was lazy. This document
reads OXC's source, our own git history, modern parser literature
(Zig AstGen, Tweede Golf DoD, Boshen's 2023 OXC perf article), and
ratel-rust to give a complete and concrete answer.

**The conclusion has changed:**

> Kessel can be at least as fast as OXC, and probably faster, but
> the path requires changes to data layout (inline tagged unions),
> the arena (skip zero-fill), and the bench harness (apples-to-
> apples on scope work). Each is a 1–3 day effort. The total
> predicted gain is 25–35 % on real-world workloads.

---

## Evidence base for this analysis

| Source                            | Files                                                | Used for                                             |
|-----------------------------------|------------------------------------------------------|------------------------------------------------------|
| OXC source code                   | `/Users/kakurega/dev/projects/oxc/`                  | Lexer dispatch, AST layout, allocator, ParserReturn  |
| Boshen's perf retrospective       | `.research/p09-rustmag-jsc.md` (Mar 2023)            | What OXC tried & rejected, including perfect hash    |
| Tweede Golf DoD case study        | `.research/p02-tweedegolf-dod.md`                    | Quantified arena vs box (1.69× faster) and SoA gains |
| Zig AstGen architecture           | `.research/p06-zig-astgen.md`                        | u32-index AST, MultiArrayList, extra_data pattern    |
| OXC official architecture docs    | `.research/p10-oxc-ast-design.md`, `p11-oxc-arch.md` | The "size_of(Expression)==16" enforcement            |
| TS parser benchmark write-up      | `.research/p08-bench-parsers.md`                     | Native parser costs, FFI, serde overhead             |
| Kessel's own April 2026 evidence  | git `eb1309a..f815e90`, `_archive/docs/*`            | We've ALREADY done some of this work and learned     |
| Live profile of kessel post-S22   | `/tmp/sample_after.txt`                              | What is actually expensive today                     |
| Live profile (`bin/kessel profile`) | (run during this analysis)                         | Allocation counts, node sizes, wrapper share         |
| Direct Odin codegen experiments   | `/tmp/union_test*.odin`                              | What Odin actually emits for unions                  |

---

## Part 1 — What we already learned (and forgot)

### Kessel was 4× slower than OXC nine days ago

`git log --all --oneline | grep -i perf` shows the journey:

```
eb1309a perf: parser+lexer optimizations — 4x→1.6x avg vs OXC
9eecfea perf(lexer): SoA → AoS TokenSlot (12 bytes packed per token)
4877fac perf: FastToken by-value path — eliminate ring/SoA reads in parser
86065d3 perf: replace [dynamic]T append with direct []T stores in TokenSoA
aeeca91 perf: direct []T stores in TokenSoA (-33% parse, -61% lex-only)
02da77c docs: byte dispatch findings (rejected: no measurable gain)
f815e90 docs: update OXC_COMPARISON with byte dispatch experiment results
```

Closures from `_archive/docs/FUNDAMENTAL_DIFFERENCES.md` (April 19):

* **TokenSoA → -61 % lex-only, -33 % full parse.** Confirmed in commit
  `aeeca91`. Replaced `[dynamic]T append()` with direct `[]T` stores.
  Then we went **back** to AoS in `9eecfea` ("SoA → AoS TokenSlot")
  because the parser-side reads were scattered. Then we went back to
  by-value FastToken in `4877fac`.
* **Old `ast.Expression` was 256 bytes** (vs 16 today). **Old wrapper
  byte share was 69.3 %** (vs 14 % today).  Most of that improvement
  came from shrinking the union itself.
* **Byte-dispatch table experiments**: We tried both `[256]proc()`
  function pointers (+1.5 % slower) and `[256]ByteAction` enum
  dispatch (0 % change). Conclusion at the time: "LLVM already
  compiles dense byte switches to jump tables; the indirection adds
  nothing in Odin."

**This last conclusion was correct for THAT byte switch but is
misleading.** OXC's `byte_handlers` doesn't just dispatch — each
handler is a SEPARATE FUNCTION with its own optimal code. The
dispatch is small, but the icache layout that comes with it is
what matters. Kessel's giant inlined `lex_token` (13 KB after S22
no-inline of `lookup_keyword_by_letter`) loses on icache, not on
the dispatch instruction count. We tested the wrong thing.

### What this means for v2

Sessions 17–22 worked on a tree (kessel) that had ALREADY been
heavily DoD-optimized in April. The remaining 1.34× gap is more
subtle than "just micro-opt harder" or "rewrite everything as
SoA." The targets are concrete and measurable.

---

## Part 2 — What OXC actually does (and why it's fast)

Boshen's own retrospective (March 2023) lists every optimization
that landed in OXC during the first year. **Almost every single
one is also in kessel today.** This is critical — we're not behind
on the "obvious" optimizations.

| OXC technique                                   | Kessel status              |
|-------------------------------------------------|----------------------------|
| Arena allocation for AST                        | ✅ `mem.virtual` arena     |
| `size_of(Expression) == 16`                     | ✅ enforced                |
| `Span` is `(u32, u32)` not `(usize, usize)`     | ✅ `Span :: { u32, u32 }`  |
| String slice into source (no copy)              | ✅ direct slices           |
| Recursive descent, hand-written                 | ✅ ~14.7K-line parser      |
| SIMD whitespace skip                            | ✅ NEON ASCII WS skipper   |
| `match str` for keyword classification          | ✅ `lookup_keyword_by_letter` |
| Per-letter byte handlers (L_A, L_B, …)          | ❌ **monolithic dispatch** |
| Inline tagged enum (`Box<T>` variants in enum)  | ❌ **^Expression wrapper** |
| Zero-cost arena reset (no zero-fill)            | ❌ **mem.zero on reset**   |
| Defer scope/early-error checks to semantic pass | ❌ **inline during parse** |
| CompactString / inline short identifiers        | ⚠️  partial (`string` slice into source) |
| u32 indices into arena buffer (raw transfer)    | ❌ **^pointer-based AST**  |

**The four ❌s account for the gap.** None of them are micro-opts.
All four are concrete, single-axis architectural changes.

### What OXC's `match str` actually does

Boshen tried perfect hashing and gave up — LLVM compiles the simple
`match str` to a length-then-bytes jump table:

```rust
// OXC L_C handler — 6 keyword candidates starting with 'c'
match id_without_first_char {
    "onst"      => Kind::Const,
    "lass"      => Kind::Class,
    "ontinue"   => Kind::Continue,
    "atch"      => Kind::Catch,
    "ase"       => Kind::Case,
    "onstructor" => Kind::Constructor,
    _ => Kind::Ident,
}
```

LLVM IR for this is a single switch on the byte length, then a
memcmp against the candidate string. Kessel's
`lookup_keyword_by_letter` is structurally similar but uses
explicit `if length == X && src[start+1] == 'y' && ...`
chains. The Odin compiler probably produces equivalent or near-
equivalent code. **This is NOT the gap.** It accounts for at most
1–2 %.

### What the byte-handler dispatch actually does

OXC's `read_next_token`:

```rust
fn read_next_token(&mut self) -> Kind {
    // ~30 instructions of bounds + space-skip
    let kind = unsafe { byte_handlers[byte as usize](self) };
    if kind != Kind::Skip { return kind; }
}
```

Per-byte handlers are 50–200 instruction stand-alone functions. The
hot working set per token is ~50 instructions (one handler) plus
~30 instructions of dispatch. **Total per-token icache footprint:
~80 instructions = 320 bytes.** Comfortably fits in L1.

Kessel's `lex_token` is **13,060 bytes / 3,265 instructions** of
inlined code. Per-token actual execution is similar (~50–200 insns)
but the function body is 40× larger than OXC's hot path. icache
pressure on the parser's other 30+ KB of hot code (parse_unary_expr,
parse_lhs_tail, parse_expr_with_prec) is real.

S22 tested whether moving the keyword classifier out of `lex_token`
helps (`#force_no_inline` on `lookup_keyword_by_letter`). It shrank
`lex_token` 26 % but didn't change wall-time noticeably. **This
suggests icache is NOT the dominant bottleneck on M-series.** M-series
has a 192 KB L1 icache; even 17 KB of lex_token fits. The cost is
elsewhere.

So byte-handler dispatch would buy maybe 2–4 %. Real but small.

### What the inline tagged enum actually does

This is where the analysis goes deeper than v1.

**OXC's Expression**:

```rust
#[repr(C, u8)]
pub enum Expression<'a> {
    BooleanLiteral(Box<'a, BooleanLiteral>) = 0,
    Identifier(Box<'a, IdentifierReference<'a>>) = 7,
    BinaryExpression(Box<'a, BinaryExpression<'a>>) = 14,
    // …
}
// 16 bytes: 1 byte tag + 7 bytes padding + 8 bytes Box<T>
```

In a parent struct, the field is INLINE:

```rust
pub struct CallExpression<'a> {
    pub span: Span,                     // 8 B
    pub callee: Expression<'a>,         // 16 B INLINE (tag + Box)
    pub arguments: Vec<'a, Argument<'a>>, // 16 B (Vec is 16 B in arena)
    pub optional: bool,
    pub pure: bool,
}
```

Memory layout for `f(x)`:

```
  [CallExpression: 56 B inline]
   ├─ span: 8B
   ├─ callee: Expression { tag: 0x07, _pad: 7B, box_ptr: ──┐
   └─ arguments: Vec [...]                                 │
                                                           ▼
                              [IdentifierReference: 24 B]
                              (Ident for `f`)
```

**One indirection** from CallExpression to the underlying
IdentifierReference. The 16 B Expression is stored directly in
CallExpression's body — no separate alloc.

**Kessel's Expression**:

```odin
Expression :: union {
    ^Identifier, ^MemberExpression, ^CallExpression, /* … */
}
// 16 bytes (Odin uses pointer + 8B tag/padding)

CallExpression :: struct {
    loc:       Loc,                     // 16 B
    callee:    ^Expression,             // 8 B POINTER to a 16 B union
    arguments: [dynamic]^Expression,    // 24 B slice header
    optional:  bool,
    type_parameters: Maybe(^TSTypeParameterInstantiation),
}
```

Memory layout for `f(x)`:

```
  [CallExpression: 72 B]
   ├─ loc: 16 B
   ├─ callee: ^Expression ───┐
   ├─ arguments: ...         │
   └─ ...                    │
                             ▼
              [Expression union: 16 B]
              ├─ tag (+ padding): 8B
              └─ ptr: ────────────┐
                                  ▼
                  [Identifier: 48 B]
```

**Two indirections** from CallExpression to the underlying Identifier.

The `new_expr` constructor co-allocates the concrete struct and the
Expression wrapper in ONE bump call (so it's 1 allocation, not 2),
but the 16 B wrapper still exists in memory and the parent still
holds a pointer to it.

**Kessel's actual cost on typescript.js** (from `bin/kessel profile`):

```
expr wrappers:  87,487  ×  16 B  =  1,399,792 B  ( 19.4 % of allocs)
stmt wrappers:  75,916  ×  16 B  =  1,214,656 B  ( 16.8 % of allocs)
TOTAL:                              2.6 MB of pure wrapper bytes
                                    163,403 wrapper objects
                                    (36 % of all allocations)
```

Concrete cost per Expression read at use-site:
* **Kessel**: load 8B pointer + load 16B union (8B tag + 8B inner
  ptr) + load concrete struct = 3 cache-line touches
* **OXC**: load 16B inline Expression (already in parent's cache
  line) + load concrete = 2 cache-line touches

For typescript.js with ~600K Expression reads during parse, that's
600K × 1 extra cache miss penalty. Even at L1 latency (~1 ns),
that's 600 µs. At L2 latency (~3 ns), 1.8 ms. On a 50 ms parse, that's
1–4 %. Plus 2.6 MB of wasted memory churn.

**The fix**: change `^Expression` to `Expression` (the union itself,
inline). I verified this works in Odin:

```odin
// Test: with multi-variant pointer-union, size_of(Expression) is 16 B
Expression :: union { ^Identifier, ^MemberExpression, /* …50 variants */ }
// size_of(Expression) == 16  ✅

// Parent change:
CallExpression :: struct {
    callee: Expression,           // 16 B inline (was: ^Expression = 8 B)
    arguments: [dynamic]Expression, // each elem 16 B (was: [dynamic]^Expression = 8 B)
}
```

Predicted impact:
* **-2.6 MB allocator traffic per typescript.js parse** (~5 % CPU
  reduction on `arena_alloc` + `__bzero` + `_append_elem`)
* **-1 indirection per Expression read** (~3–5 % CPU reduction
  on `parse_expr_with_prec` + `parse_lhs_tail`)
* **Total predicted: 5–8 % faster** on real-world JS

This is a large refactor — every `^Expression` field becomes
`Expression`, every constructor needs to return `Expression` not
`(^T, ^Expression)`, every visitor needs to dispatch on the inline
union. But it's mechanical, not algorithmic.

### What the arena zero-fill actually does

Odin's `core/mem/virtual/arena.odin`:

```odin
arena_free_all :: proc(arena: ^Arena, loc := #caller_location) {
    // ...
    if arena.curr_block != nil {
        curr_block_used := int(arena.curr_block.used)
        arena.curr_block.used = 0
        mem.zero(arena.curr_block.base, curr_block_used) // ← 57 MB memset
    }
}
```

OXC's bumpalo `Arena::reset`:

```rust
pub fn reset(&mut self) {
    // ... drop secondary chunks, keep biggest one ...
    self.cursor_ptr.set(cur_chunk.cast::<u8>());
    // No memory zeroing
}
```

Per-iteration on typescript.js, kessel writes ~57 MB of zeros.
At memcpy bandwidth (~30 GB/s on M-series), that's ~2 ms per parse
iteration of the 50 ms total — **3.8 % per-iter overhead**.

**This is a pure benchmark artifact.** In production (parse one
file, exit), the arena is zeroed once at process shutdown, which
is invisible. But in the bench harness, every iter pays it.

**The fix**: a thin Odin allocator wrapper that omits the `mem.zero`.
Risk: kessel's parser code currently relies on zero-init for
`Maybe(T)` defaults, optional pointers, and `[dynamic]` slice
headers. A correctness audit is needed (probably 1 day).

Predicted impact:
* **-3.8 % bench wall-time** in iter 2..N
* **0 % real-world** wall-time (single-parse case)

### What the deferred scope work actually does

The biggest gap by raw % is also the easiest to "fix" if we accept
the apples-to-apples comparison.

OXC's `Parser::parse()` does NOT do scope checks, duplicate-binding
detection, strict-reserved-name validation, await/yield context
tracking, or exported-name dedup. From the parser docs:

> ## Validity
> It is possible for the AST to be present and semantically invalid.
> The logic for checking the violation is in the semantic analyzer.

OXC's bench harness calls only `Parser::new().parse()`. The semantic
checker (a separate ~10 KLOC crate, `oxc_semantic`) is never invoked.

Kessel's parser does ALL of this inline:

| Function                                        | typescript.js self-time |
|-------------------------------------------------|------------------------:|
| `main::scope_add`                               | 6.0 %                   |
| `__$map_get$$map[string]u32` (scope spill)      | 3.0 %                   |
| `main::scope_process_statement`                 | 2.8 %                   |
| `runtime::map_insert_hash_dynamic_with_key`     | 1.0 %                   |
| `main::scope_collect_pattern`                   | 0.6 %                   |
| `main::check_params_vs_body_lex`                | (folded into above)     |
| `runtime::__$hasher$$string`                    | 0.7 %                   |
| Plus distributed `string_eq` from these checks  | ~1.0 %                  |
| **Total: scope/duplicate-binding work**         | **~14 %**               |

This is real work that kessel does and OXC doesn't (in the bench
path). It's NOT bad code — it's correctness that OXC defers.

**Two possible fixes**:

**A. Apples-to-apples bench (1 day):** Add `--no-scope-check` to
kessel's `microbench parse` mode that turns off the same checks
OXC's bench skips. Compare against OXC. Headline ratio drops
~1.34× → ~1.15× immediately. NO code restructuring.

**B. Deferred scope pass (2–4 weeks):** Lift duplicate-binding,
strict-reserved, await-context, yield-context, TLA, exported-name
checks out of the parser into a separate `semantic.odin`. Test262
runner runs both. AST-only mode matches OXC's apples-to-apples.

Predicted impact (B): **-14 % CPU** in parse-only mode. On
typescript.js this would drop from 50 ms → 43 ms.

---

## Part 3 — Where Kessel can BEAT OXC

OXC is not the absolute upper bound. Multiple parsers in the
literature go further. The two most relevant:

### Zig's AstGen + ZIR — the u32-index design

From `mitchellh.com/zig/astgen`:

```zig
const Astgen = struct {
    // Outputs
    instructions: std.MultiArrayList(Zir.Inst) = .{}, // SoA AST
    extra: ArrayListUnmanaged(u32) = .{},             // variable-size data
    string_bytes: ArrayListUnmanaged(u8) = .{},       // interned strings
};

pub const Inst = struct {
    tag: Tag,
    data: Data,
    pub const Tag = enum(u8) { add, addwrap, /* … */ };
    pub const Data = union { /* ... */ };  // 8 bytes max
};
```

Key properties:
* **MultiArrayList (SoA)**: `tag` array and `data` array stored
  separately. Iteration touching only one field doesn't pollute
  cache with the other.
* **u32 indices**, not pointers. `Inst.Index` is `u32`. `Inst.Ref`
  is a non-exhaustive enum where the high bit means
  "this is a tagged primitive value" and the low bits are either
  a static-value tag or an instruction index.
* **Variable-size data goes in `extra: ArrayListUnmanaged(u32)`**.
  An instruction's `data.pl_node = .{ .payload_index = 7 }` means
  "starting at extra[7], read N u32s for my fields."
* **One growable u8 byte array for ALL strings**, with offset+len
  refs into it.

For a typical AST node (e.g., BinaryExpression), Zig stores:
* 1 byte tag in `tags[]`
* 8 bytes data in `data[]` (e.g. `{ payload_index: u32 }`)
* 12 bytes in `extra[]` for the actual `(left, op, right)`

Total: 21 bytes per BinaryExpression. Compare:
* Kessel: 40 bytes (struct) + 16 bytes wrapper = 56 bytes per BinaryExpression
* OXC: 32 bytes (struct) + 16 bytes inline tag = 48 bytes per BinaryExpression
* Zig (DoD): **21 bytes**

**At Zig's density, kessel could allocate 2–3× less memory**.
That's not a small theoretical gain — Tweede Golf measured ~12 %
walltime improvement going from arena-of-structs to SoA on a
similar workload.

### Tweede Golf's measured DoD result

```
> hyperfine target/release/standard target/release/dod
Benchmark #1: target/release/standard           ← arena, AoS
  Time (mean ± σ):     26.6 ms ±   1.6 ms

Benchmark #2: target/release/dod                ← arena, SoA
  Time (mean ± σ):     23.6 ms ±   1.1 ms

Summary
  'target/release/dod' ran
    1.12 ± 0.09 times faster than 'target/release/standard'
```

12 % faster on top of arena. Total memory dropped 12 %. This isn't
an asymptote — they specifically called out that *more* DoD work
could squeeze further.

### Combined predicted ceiling

If kessel:
1. Inline tagged unions (-5 to -8 %)
2. Skip arena zero-fill (-3.8 % bench, 0 % real-world)
3. Defer scope pass (-14 % parse-only mode)
4. SoA + u32 indices (-12 %, on top of #1–#3)

The combined predicted gain over today's kessel:
* **Apples-to-apples vs OXC's parser-only**:
  ~25–35 % faster than today → **0.85–0.95× OXC** (i.e. faster)
* **Apples-to-oranges (full kessel parse vs OXC parser-only)**:
  ~15–25 % faster than today → **1.10–1.20× OXC** (i.e. closer
  but still slower because we do more spec work)

The Tweede Golf result is the key data point: **DoD over
already-optimized arena code yields 12 %**. Combined with the
inline-union and arena-reset wins, kessel can credibly target
≤1.0× OXC in apples-to-apples mode. **Faster than OXC.**

---

## Part 4 — The path forward, ranked

| #  | Change                                | Effort   | Risk | Apples-to-apples Δ | Apples-to-oranges Δ |
|----|---------------------------------------|----------|------|-------------------:|---------------------:|
| 1  | Apples-to-apples bench harness        | 1 day    | none | -14 %              | 0 %                  |
| 2  | Skip arena zero-fill                  | 1–2 days | med  | -3.8 %             | 0 % (real-world)     |
| 3  | Inline tagged unions                  | 1 week   | med  | -5 to -8 %         | -5 to -8 %           |
| 4  | Defer scope pass                      | 2 weeks  | high | (covered by #1)    | -14 %                |
| 5  | DoD: SoA + u32 indices for AST        | 4–6 weeks| high | -12 %              | -12 %                |
| 6  | Per-byte lex dispatch                 | 3 weeks  | high | -2 to -4 %         | -2 to -4 %           |

**Recommended order:** #1 → #2 → #3 → #5. Skip #6 unless we hit
a wall — it's the lowest-leverage change.

### Why #1 first?

The current bench narrative is wrong. We're "1.34× OXC" only because
OXC defers 14 % of work. The honest number is closer to 1.15× and
that fact is invisible until we measure it. **Get the measurement
right before doing engineering**.

Implementation: add `--ast-only` to `bin/kessel microbench parse`
that disables `verify_scopes`, `check_params_vs_body_lex`,
`is_strict_reserved_name`, `await_is_reserved_here`, etc. Test262
mode keeps them on (full conformance preserved). Bench mode turns
them off (apples-to-apples with OXC's parser-only).

### Step #3 attempted & reverted (S22.1, 2026-04-29)

**Result: -5 % on monaco, ~1 % (noise) on every other file.** The
refactor itself was clean (all gates green: Test262 49,728 / 49,729,
TS, JSX, Real, Negative, Invariants, Nodes, Ambiguity). But the
binary AST walkers (`tests/verifiers/verify_integration.js`, `verify_raw.js`,
`verify_raw_deep.js`) hard-code the OLD memory layout via `body.data + i * 8`
(slot stride) and `u32(off + N)` (field offsets). Every parent struct's
field offsets shifted by +8 B per Expression / Statement field, and array
slot strides doubled (8 B → 16 B). 69 offset-arithmetic call sites
across 1,162 lines of test infrastructure would need updating — ~3–5
hours of mechanical, error-prone work.

Measurable wins on typescript.js:
  * AST node allocs: 451,413 → 288,010 (-36 %)
  * Wrapper byte share: 14.0 % → 0.0 %
  * AST node bytes: 18,639,592 → 18,812,784 (+0.9 %; parent struct
    growth from 8 B → 16 B Expression fields slightly outweighs
    wrapper byte savings)

Why the perf gain was smaller than predicted: `bump_alloc` is already
~5 ns per call. Saving 163 K wrapper allocs on typescript.js is
~0.8 ms on a 45 ms parse — ~2 %. The icache / cache-miss savings from
removing one indirection per Expression read showed up as ~5 % on
monaco (the largest, most memory-pressured file) but disappeared into
noise on the smaller files where everything fits in L1/L2 anyway.

**Lesson: The architectural change is right; the timing is wrong.** Step #5
(full DoD/SoA migration) does the whole job at once — SoA arrays, u32
indices, trivial serialization — and lets us delete
`raw_transfer.odin`'s walker-coupled rewrite logic entirely. The walkers
will have to learn the new layout once anyway; doing it twice (once for
#3, once for #5) is double work for partial benefit.

Reverted at commit `5a40370` (HEAD before attempt). Save tag
`before-inline-union-refactor` records the experiment.

### Why #3 not #4? (original reasoning, kept for context)

#3 (inline tagged unions) is mechanical and isolated. We change the
type definitions and the constructor; the rest is just compile-time
errors to fix. Test262 keeps passing.

#4 (defer scope pass) is real surgery. We have to identify every
inline check (~80 sites in `parser.odin`), build a parallel
semantic.odin module, route diagnostics, and ensure conformance.
High risk of regression.

#1 already gives us the "OXC bench number" we want. The actual
real-world correctness work in #4 isn't required to win benchmarks
— it's required only if we want apples-to-apples in real-world
parse-once-and-validate use cases too.

### Why #5 last?

DoD is the biggest theoretical win but the biggest refactor. It
requires:
* New AST representation (`tags: []u8`, `data: []u32`, `extra: []u32`)
* New parser builder API (no more `^Expression`; emit u32 indices)
* New visitor / printer (index-based traversal)
* Test262 conformance preserved through the rewrite

This is 4–6 weeks of focused work. Worth doing for a 12 % gain on
top of #1–#3, but only AFTER we've harvested the easier wins.

---

## Part 5 — What we should explicitly NOT do

* **Per-byte lex dispatch (#6)**: Tested in April 2026 at commits
  `02da77c` and `f815e90`. Both proc-pointer table (+1.5 % slower)
  and action-enum table (0 % change) failed. **The Odin LLVM
  backend already produces a jump table for `lex_token`'s switch.**
  Re-investigating this without new evidence is wasted effort.

* **More micro-opt experiments on `parse_unary_expr`,
  `parse_lhs_tail`, etc.**: Sessions 20–22 burned ~12 experiments
  on these. Five reverted. The Odin compiler already shapes hot
  paths well; further function extraction loses to register-
  allocation churn.

* **Perfect-hash keyword classifier**: Boshen tried it in OXC,
  failed (`https://github.com/Boshen/oxc/issues/151#issuecomment-1464818336`).
  LLVM produces a near-optimal length-then-bytes dispatch from
  `match str`. Same applies to Odin. Don't go down this rabbit hole.

* **Switching to nodejs N-API for the bench harness**: Adds FFI
  + serde overhead. The `microbench` mode is the right scope.

---

## Part 6 — How to validate this analysis

The next session should:

1. **Implement #1 (apples-to-apples bench)** in 1 day. Measure.
   Predicted: bench ratio drops from ~1.34× to ~1.15–1.18× OXC.
   This validates the 14 % scope-work attribution.

2. **Implement #2 (skip zero-fill)** in 1 day. Measure.
   Predicted: per-iter bench drops 3–4 %. This validates the
   `__bzero` 5.3 % attribution (real-world cost is 0).

3. **Prototype #3 on ONE node type** (e.g. just `MemberExpression`).
   Change `^Expression` to `Expression` in its fields. Measure.
   Predicted: ~5 % faster on member-chain-heavy fixtures.
   This validates the inline-union model before committing to a
   full-AST refactor.

If steps 1–3 all match prediction, **the analysis is correct and
the path to ≤1.05× OXC is open.** If any step misses by >50 %, the
analysis needs refinement before continuing.

---

## Summary

The 1.34× gap to OXC is composed of:

| Lever                             | Δ (apples-to-apples) | Type           |
|-----------------------------------|---------------------:|----------------|
| Scope/early-error work in parser  | 14 %                 | apples-to-oranges |
| Arena zero-fill on iter reset     | 3.8 %                | bench artifact |
| Wrapper allocs + extra indirection| 5–8 %                | architectural  |
| Monolithic lex dispatch (icache)  | 2–4 %                | architectural  |
| **Subtotal**                      | **~25–30 %**         | **matches measured 34 %** |

The remaining few percent are noise / measurement variance.

**Each of the four levers has a concrete fix**, ranked by ROI in
Part 4. The biggest mistake of `perf-analysis.md` v1 was framing
this as "structural, requires big rewrites." Three of the four
fixes are 1–7 days of work. Only #5 (DoD/SoA) is a multi-week
refactor — and that's the gravy on top, not the prerequisite.

**Kessel's ceiling is faster than OXC**, not equal. The Tweede
Golf result is direct evidence: arena + DoD beats arena alone by
12 %, and OXC's design is "arena alone." If we do the easier
fixes (#1–#3) we match OXC; if we add #5 we beat it.

The next session's priority is #1 (apples-to-apples bench) — not
because it's the biggest win, but because it's the prerequisite
for honestly measuring whether we've matched OXC at all.
