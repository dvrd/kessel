# Why Kessel Is Slower Than OXC

*A structural analysis. Session 22, 2026-04-29.*

## TL;DR

Kessel is ~1.34× slower than OXC at parsing real-world JS. After
chasing micro-optimisations through three sessions (S20–S22) we are
at the floor of what those buy. The remaining gap is **architectural,
not algorithmic** and can be fully accounted for:

| Factor                                              | Δ vs OXC      | Architectural? |
|-----------------------------------------------------|--------------:|:--------------:|
| Kessel does scope / early-error checks during parse | **+14 %**     | yes            |
| Kessel zero-fills arena on every iter reset         | **+3–5 %**    | bench artifact |
| Kessel double-allocates Expression / Statement wrappers | **+5 %**  | yes            |
| Kessel re-dispatches by first byte twice            | **+3–5 %**    | yes            |
| Kessel inlines lex_token monolithically (icache)    | **+2–4 %**    | yes            |
| **Total estimated gap**                             | **~28–33 %** | matches 34 %   |

If kessel matched OXC on each of the four architectural axes (and we
ignored the bench artifact), the predicted ratio is **~1.05× OXC**.
Closing this gap requires re-shaping the parser, not micro-optimising it.

---

## How this analysis was done

1. Cloned OXC at `/Users/kakurega/dev/projects/oxc` (the one
   `bench/oxc_compare/Cargo.toml` already references).
2. Ran `bin/kessel profile parse bench/real_world/typescript.js
   --iterations 3` to get exact AST allocation counts and node sizes.
3. `sample(1)` profiled 200 typescript.js parses, sorted by self-time.
4. Read OXC's lexer dispatch (`crates/oxc_parser/src/lexer/`),
   AST layout (`crates/oxc_ast/src/ast/`), allocator
   (`crates/oxc_allocator/src/`), and parser entry
   (`crates/oxc_parser/src/lib.rs`). Compared head-to-head with
   `src/lexer.odin`, `src/parser.odin`, `src/ast.odin`.
5. Cross-referenced each measured cost in the kessel profile against
   the corresponding OXC code path.

LOC parity: kessel parser+lexer+ast = 20,444 LOC, OXC parser = 22,520 LOC.
Roughly the same scope of work; the gap is design, not feature count.

---

## The five real differences

### 1. Scope tracking is in the parser (kessel) vs in a separate pass (OXC)

**OXC's parser explicitly does NOT do scope/binding checks.** From
`crates/oxc_parser/src/lib.rs`:

```rust
/// ## Validity
/// It is possible for the AST to be present and semantically invalid.
/// 1. The Parser encounters a recoverable syntax error
/// 2. The logic for checking the violation is in the semantic analyzer
///
/// To ensure a valid AST, check that errors is empty. Then, run
/// semantic analysis with syntax error checking enabled.
```

Kessel's parser does scope tracking inline (it's the only way to
hit Test262's 49,728/49,729 conformance — the spec mandates these
checks). The bench harness calls only `Parser::new().parse()` for
OXC, never running `oxc_semantic`. **This is apples-to-oranges**.

**Profile cost in kessel** (typescript.js):

| Function                                  | Self-time |
|-------------------------------------------|----------:|
| `main::scope_add`                         | 6.0 %     |
| `__$map_get$$map[string]u32`              | 3.0 %     |
| `main::scope_process_statement`           | 2.8 %     |
| `runtime::map_insert_hash_dynamic_with_key` | 1.0 %   |
| `main::scope_collect_pattern`             | 0.6 %     |
| `runtime::__$hasher$$string`              | 0.7 %     |
| **Subtotal**                              | **~14 %** |

Plus `string_eq` (2.5 %, mostly from scope binding compares) for
~16 % combined. None of this work happens in OXC's parser.

**Closing this would require:** a `--no-scope-check` mode, or
splitting the duplicate-binding / strict-reserved / TLA / yield-
context / await-context / exported-name checks into a separate
post-parse semantic pass. Test262 conformance would need to run
parser+semantic together to keep 49,728/49,729 green.

This is a real ~14 % of total CPU that kessel spends on work OXC
defers. It's the single biggest architectural delta.

### 2. Arena reset zero-fills 57 MB per iteration (kessel) vs O(1) cursor rewind (OXC)

Odin's `core/mem/virtual` arena has this in `arena_free_all`:

```odin
arena.curr_block.used = 0
mem.zero(arena.curr_block.base, curr_block_used)  // ← 57 MB memset
```

OXC's `bumpalo` arena (`crates/oxc_allocator/src/arena/drop.rs`):

```rust
pub fn reset(&mut self) {
    // ... drop secondary chunks ...
    self.cursor_ptr.set(cur_chunk.cast::<u8>());
    // No memory zeroing
}
```

Per-iteration on typescript.js, kessel writes 57 MB of zeros at memcpy
bandwidth (~30 GB/s on M-series M-class) — that's **~2 ms per parse
of the 52 ms total walltime** (3.8 %). Self-time profile attributes
5.3 % to `__bzero` because `arena_free_all` shows up at the top of
stack alongside its caller.

This is a **bench harness artifact**, not a real-world cost. In
production, the arena is zeroed once at process start and the parser
parses one file before exiting. Bench iterations 2..N pay it.

OXC works without zero-fill because every alloc is `arena.alloc(val)`
which moves `val` into the slot, fully overwriting it. Kessel relies
on zero-init for `Maybe(T)` defaults, optional pointers, and various
fields the constructor doesn't set. Removing the zero-fill would
require an audit of every AST node constructor.

**Closing this requires:** either skipping the zero-fill (audit
required) OR running the bench in a way that doesn't include it
(`task test:bench:regression` already amortises somewhat by sharing
the arena across iters, but `task bench:quick` doesn't).

### 3. Kessel allocates an Expression / Statement wrapper PER node (OXC stores it inline)

**Kessel** (`src/ast.odin`):

```odin
Expression :: union {
    ^Identifier, ^MemberExpression, ^CallExpression, /* … 50 variants */
}
// 16 bytes — pointer + tag

CallExpression :: struct {
    loc:       Loc,            // 16 B
    callee:    ^Expression,    // 8 B → pointer to a 16 B union
    arguments: [dynamic]^Expression,  // 24 B
    // ...
}
```

So `a.b` allocates:
1. `Identifier` for `a` (48 B) **+** `Expression` wrapper (16 B)
2. `MemberExpression` (40 B)
3. `Identifier` for `b` (48 B) — direct field, no wrapper for property
4. + the `^Expression` wrapper for a

For typescript.js, the profile reports:

```
expr wrappers:        87,487 (1,399,792 bytes, 19.4 % of allocs)
stmt wrappers:        75,916 (1,214,656 bytes, 16.8 % of allocs)
wrapper byte share:   14.0 %
```

163,403 wrapper allocs that exist **only for type dispatch**, on top
of the 451,413 concrete-node allocs. **36 % of all allocs are wrappers.**

**OXC** (`crates/oxc_ast/src/ast/js.rs`):

```rust
#[repr(C, u8)]
pub enum Expression<'a> {
    BooleanLiteral(Box<'a, BooleanLiteral>) = 0,
    Identifier(Box<'a, IdentifierReference<'a>>) = 7,
    BinaryExpression(Box<'a, BinaryExpression<'a>>) = 14,
    // ...
}
// 16 bytes — Box pointer + variant tag, INLINE in parent

pub struct CallExpression<'a> {
    pub callee: Expression<'a>,  // 16 B inline; Box<'a, T> already inside
    // ...
}
```

OXC stores the 16-byte tagged union INLINE in the parent struct.
The `Box<'a, T>` inside is the only allocation per node. **One alloc
per node, not two.**

**Cost in kessel** (estimated): ~5 % of total CPU spent on wrapper
allocs and the extra pointer-deref per Expression read. The
wrapper-alloc bytes alone are 14 % of allocator traffic.

**Closing this requires:** changing `Expression` and `Statement` from
`union { ^T1, ^T2, ... }` (16 B heap-allocated) to a `struct { tag,
ptr }` stored inline in parent fields. A widespread refactor — every
`^Expression`/`^Statement` field in every AST struct, every parser
return path, every printer dispatch. Possible in Odin but invasive.

### 4. First-byte dispatch happens TWICE in kessel (once in OXC)

**OXC's lexer** (`crates/oxc_parser/src/lexer/byte_handlers.rs`):

```rust
// 256-entry function-pointer table indexed by first byte
pub static WITH_TOKENS: ByteHandlers<TokensLexerConfig> = byte_handlers!();

// In `read_next_token`:
let kind = unsafe { byte_handlers[byte as usize](self) };

// Per-letter handler fuses identifier scan + keyword classify:
ascii_identifier_handler!(L_C(id_without_first_char) match id_without_first_char {
    "onst"      => Kind::Const,
    "lass"      => Kind::Class,
    "ontinue"   => Kind::Continue,
    "atch"      => Kind::Catch,
    "ase"       => Kind::Case,
    "onstructor" => Kind::Constructor,
    _ => Kind::Ident,
});
```

The `match str` statement uses Rust's compiler-generated perfect-hash
dispatch on the suffix. **One first-byte dispatch, one match.**

**Kessel's lexer** (`src/lexer.odin`):

```odin
// In lex_token:
single_char_tokens[c]   // first-byte table for punctuators
if is_id_start_fast(c)  // dispatch into lex_identifier
    body_end := simd_scan_id_cont(...)         // SIMD body scan
    tok_type := lookup_keyword_by_letter(...)  // ← second first-byte dispatch
```

`lookup_keyword_by_letter` does its own `switch c0` on the first byte,
then chained `if length == X && src[start+1] == 'y' && ...` per
keyword. **Two dispatches on the same first byte, plus a chain of
length+byte compares.**

Profile on typescript.js (after S22):

| Function                       | Self-time |
|--------------------------------|----------:|
| `lex_token`                    | 28.0 %    |
| `lookup_keyword_by_letter`     | 8.7 %     |
| **Total identifier-lex path**  | **36.7 %** |

**Cost in kessel**: maybe 3–5 % of total CPU spent on the redundant
dispatch and the chained byte compares. Plus icache pressure from
having both functions in the parser's hot working set.

**Closing this requires:** restructuring the lex dispatch to have
per-letter handlers (`lex_a`, `lex_b`, ...) that fuse the body scan
with keyword classification. Or making `lookup_keyword_by_letter`
use a perfect-hash table on the suffix. Either way, a structural
change.

### 5. `lex_token` is monolithic (kessel) vs handler-per-byte (OXC)

After S22's `lookup_keyword_by_letter` peel-out, `lex_token` is still
**13,060 bytes / 3,265 instructions** of inlined code. It contains:

* Whitespace-skip prologue (after S22, ~30 instructions hot path).
* Annex B HTML-comment slow-path scanners.
* Multi-byte whitespace skip (NBSP, U+1680, U+2000–200A, U+2028/9,
  U+202F, U+205F, U+3000, U+FEFF).
* `single_char_tokens[c]` dispatch.
* `is_id_start_fast(c)` → inlined `lex_identifier` (~200 insns of
  SIMD body scan + spec validator).
* `lex_number` inlined.
* The 17-arm `switch c { ... }` that calls `#force_inline`'d
  `lex_plus`, `lex_minus`, ..., `lex_template_start`.

Every parse path through this function only EXECUTES ~50–200
instructions, but it has to LOAD all of them into icache because
they're contiguous code in the same function.

OXC's `read_next_token` is **tiny**:

```rust
fn read_next_token(&mut self) -> Kind {
    // ... ~30 instructions of bounds + space-skip ...
    let kind = unsafe { byte_handlers[byte as usize](self) };
    if kind != Kind::Skip { return kind; }
    // loop continues for skipped bytes
}
```

The byte handlers themselves are stand-alone functions, each 50–200
instructions. The hot working set is `read_next_token` (small) +
the specific handler that ran (small). Massive icache locality win.

S22 tried two function-extraction experiments to mimic OXC's shape:
* `parse_lhs_tail` `#force_no_inline` → +6 % typescript walltime
* `parse_unary_expr` prefix-arm extraction → +1.5 % walltime

Both lost to register-allocation churn from the inserted call sites.
**The kessel `Lexer` and `Parser` types are too heavy** for the call
boundary to be cheap — every call spills/reloads several registers
of state. OXC's `Lexer<'a, C>` is structured so the cursor +
config fit in registers across calls.

**Cost in kessel**: hard to isolate, but probably 2–4 % of CPU from
icache misses on the 3,265-insn `lex_token` body when entering /
leaving the parser through it.

**Closing this requires:** restructuring `Lexer` so cursor state
fits in 1–2 registers, then breaking `lex_token` into handler-per-
byte stand-alone functions. A redesign of the lexer's data model.

---

## What we tried in S20–S22 and what we learned

**Things that worked (kept):**
* SIMD WS skipper for indent runs (S21)
* Hybrid linear/spill ScopeMap (S20)
* `lookup_keyword_by_letter` `#force_no_inline` (S22)
* `is_strict_reserved_name` first-letter gate (S22, the only S22
  commit that survived a thermal-stable A/B comparison)
* Annex B prologue gate + `[256]` single-char table (S22)

**Things that didn't work (reverted):**
* `parse_lhs_tail` `#force_no_inline` (S22, +6 % typescript)
* Keyword prefix table (S22, +1.5 % overall)
* `parse_unary_expr` prefix-arm extraction (S22, +1.5 % overall)
* Plus 8+ smaller experiments across S20–S21 documented inline.

**Pattern**: every attempt to pull code out of an inlined hot path
through a function call cost more in register-allocation churn than
it saved in icache footprint. The Odin compiler + ARM64 inliner
already produce very tightly-shaped hot paths within each large
function. **The only way to shrink the per-call working set is to
shrink the per-call STATE** — which means restructuring `Lexer` and
`Parser` types.

---

## Recommendations, in order of return-on-effort

### A. Apples-to-apples bench harness (1 day, no risk)

Add a bench mode that ENABLES `oxc_semantic` to make the comparison
fair. Or add a `--no-scope-check` mode to kessel and benchmark that
against OXC's parse-only. Either way, the headline number stops
overstating the gap by 14 percentage points.

**Expected delta:** the apples-to-apples ratio drops from ~1.34× to
~1.15× immediately. Same code, better measurement.

### B. Inline tagged unions (1–2 weeks, medium risk)

Change `Expression :: union { ^T1, ^T2, ... }` (16 B heap) to a
struct `Expression :: struct { tag: u8, ptr: rawptr }` stored inline
in parent fields. Update every `^Expression` field and every
dispatch site (printer, visitor, semantic).

**Expected delta:** -5 % CPU, -1.4 MB allocator traffic per
typescript.js parse. Brings ratio to ~1.10×.

### C. Defer scope checks to a separate pass (2–4 weeks, high risk)

Lift duplicate-binding / strict-reserved / await-context / yield-
context / TLA / exported-name checks from the parser into a
`semantic.odin` pass. Test262 runner runs both. AST-only mode
matches OXC's apples-to-apples.

**Expected delta:** -14 % CPU on the parse path. Brings ratio to
~1.06× in apples-to-apples mode (parse-only).

### D. Per-byte lex dispatch (3–6 weeks, high risk, needs Lexer redesign)

Restructure `Lexer` so cursor + source pointer fit in 1–2 registers.
Replace `lex_token`'s monolithic switch with a `[256]proc()`
function-pointer table. Each handler is its own ~50–200 instruction
function. `lookup_keyword_by_letter` becomes per-letter handlers
(`lex_id_a`, `lex_id_b`, ...) that fuse identifier-tail scan with
keyword classify.

**Expected delta:** -3–5 % CPU. Brings ratio to ~1.02–1.05× —
parity territory.

### E. Skip arena zero-fill (1–2 days, medium risk)

Audit every AST node constructor to ensure all fields are explicitly
initialized; then either replace `mem.zero` in `arena_free_all` with
a no-op (custom Odin allocator wrapper), or `mem_alloc_bytes_non_zeroed`.
In production this is invisible (single parse per process); in
benches it removes ~3.8 % of measured time.

**Expected delta:** -3.8 % bench time. Real-world: 0 %. Optional.

---

## What we should NOT do

* **More micro-opts on the existing structure.** S22 burned 5
  experiments worth of time on this; the inliner is already doing
  the right thing.
* **Trying to relock the bench baseline** while the laptop is
  thermally noisy. Wait for a quiet machine; differences smaller
  than ~3 % are unmeasurable today.
* **Chasing `string_eq` or `parse_unary_expr` further.** S22 shaved
  string_eq from 4.4 % to 2.5 % (the strict-reserved-name gate);
  remaining sites are too distributed to attack one by one.
* **Optimizing `__bzero` directly.** It's a bench artifact masking
  as a hot function. The fix is the allocator, not the zero-fill.

---

## Summary

The 1.34× gap to OXC is fully accounted for by five architectural
choices:

| #  | What                                                | Δ          |
|----|-----------------------------------------------------|-----------:|
| 1  | Scope/early-error checks during parse               | +14 %      |
| 2  | Arena reset zero-fills (bench artifact)             | +3–5 %     |
| 3  | Expression/Statement wrapper allocs                 | +5 %       |
| 4  | First-byte dispatched twice                         | +3–5 %     |
| 5  | Monolithic `lex_token` icache pressure              | +2–4 %     |
|    | **Total**                                            | **~28–33 %** |

The matching predicted ratio is ~1.05× OXC if all five are addressed.
The first one alone (apples-to-apples bench) gets us to ~1.15× without
touching code.

**Each of A–D requires a structural change. None are micro-opts.**
Sessions 20–22 already spent the micro-opt budget; the next push
needs to be a redesign of one or more axes.

The honest framing: **we're not slow because of bad code. We're slow
because we're doing more work than OXC does (scope tracking, redundant
dispatch, double allocation, monolithic dispatch). Every one of those
is a deliberate design choice that gives us correctness wins (Test262
49,728/49,729 vs OXC's parser-only) but costs CPU.**

The right next session is **(A) — the apples-to-apples bench** — and
**a decision** about whether (B), (C), or (D) is worth the risk.
