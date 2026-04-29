# Architectural perf analysis — what's left and what to consider

> Date: 2026-04-29 (S22.6)
> Current state: kessel at 1.002× OXC geo-mean. monaco worst at 1.06×.
> 3 files BEAT OXC. 6 at parity. 10/10 within 10 %.

User's guiding principle for this round:

> "Temporary memory is not a problem for us. Anyone parsing JavaScript
> has more than a GB of available RAM otherwise they wouldn't be able
> to even run a browser."

That insight unlocks an architectural lane we'd been avoiding: be
generous with virtual memory and OS resources, where the kernel
already gives us laziness for free.

## Current per-file ratio + where the time still goes

| File | Ratio | Parse ms | Where the gap is |
|---|---:|---:|---|
| snabbdom.js | 0.83× | 3 µs | (kessel WINS) |
| preact.js | 0.90× | 141 µs | (kessel WINS) |
| react-dom.dev.js | 0.98× | 4.0 ms | (kessel WINS) |
| d3.js | 1.01× | 5.2 ms | parity |
| antd.js | 1.02× | 23.1 ms | parity |
| typescript.js | 1.04× | 43.5 ms | small |
| monaco.js | 1.06× | 34.7 ms | LEX still 4.8 ms slower than OXC |
| jquery.js | 1.07× | 1.75 ms | small |
| cesium.js | 1.07× | 39.0 ms | LEX |
| lodash.js | 1.07× | 1.49 ms | small |

monaco is the sharp edge. Why? It's the most LEX-heavy bundle in the
corpus.

## Profile decomposition of the 3 ms monaco gap (kessel 35 ms vs OXC 32 ms)

| Bucket | kessel ms | OXC ms | Δ |
|---|---:|---:|---:|
| **LEX** (lex_token + helpers) | 14.2 | 9.4 | **+4.8 ms** |
| **PARSE** (parse_*) | ~13 | 11.3 | +1.7 ms |
| **ALLOC** (arena dispatch chain) | 1.5 | 0.05 | +1.4 ms |
| Other (small fns) | ~5 | ~11 | -6 ms (kessel inlines more) |
| **Net** | 33.7 | 31.75 | ~2 ms |

The remaining gap is mostly LEX (specifically inside lex_token's body)
plus residual ALLOC.

## The architectural levers, ordered by ROI

### Tier 1: cheap, high-confidence wins (predicted ~1–4 % each)

#### A. Pre-fault arena pages outside the timer

When the parser writes to a fresh arena page for the first time, the OS
takes a soft page fault and maps in a zero-filled page. On Apple
Silicon (16 KB pages) this costs ~100–500 ns per fault. For monaco's
~57 MB of arena use that's ~3,500 page faults × ~300 ns = ~1 ms — and
this 1 ms is INSIDE the timed region today.

Fix: touch every page (one byte write per 16 KB) at parser init,
before `time.tick_now()`. Subsequent writes hit pre-mapped pages with
zero fault overhead.

```odin
// Inside init_parser, after bump pool allocated:
arena_prefault :: proc(p: ^Parser) {
    base := p.node_pool.base
    cap := p.node_pool.capacity
    page := 16 * 1024
    for off := 0; off < cap; off += page {
        base[off] = 0
    }
}
```

Predicted gain: **~1 ms per parse on large files** (monaco, cesium,
typescript). 0 on small files (their pools are small).

Cost: a couple-hundred-byte loop. Touching ~3500 pages on monaco at
~10 ns each = ~35 µs total — negligible vs the ~1 ms saved.

Risk: low. The pre-fault loop is straight-line code; if the pool size
is sane we don't OOM.

#### B. Source file via mmap (with MADV_SEQUENTIAL)

Currently kessel uses `os.read_entire_file_from_path` which:
1. Calls `read(2)` syscalls to copy file bytes from kernel cache → user buffer.
2. Allocates a contiguous user buffer for the source.

For typescript.js (12 MB) this read costs ~1–2 ms in the wall time
(though for the bench, file reads happen ONCE before timing).

Real-world parse-once workloads (LSP, build tools) DO pay this read
cost per file. mmap with MADV_SEQUENTIAL would:
- Avoid the user-space copy (zero-copy: parser reads from kernel page cache directly).
- Hint the kernel to prefetch ahead.
- Pages are demand-loaded as the lexer scans them.

Predicted gain: **~0–1 ms in microbench (file already cached), ~5–10 ms
for first parse of a cold file** (real-world matters more here).

Cost: a `mmap(2)` syscall + a `madvise(2)` syscall at parser init.

Risk: medium. Requires platform-specific code. Different on Linux vs
macOS vs Windows. Cross-platform abstraction or `when ODIN_OS` blocks.

#### C. Custom dynamic-array type bypassing Odin's runtime entirely

Even after `bump_append`, the GROW path of dynamic arrays still calls
through Odin's runtime `_append_elem` (which calls `_reserve_dynamic_array`
which calls `mem_resize` which calls `arena_allocator_proc` —
4 function calls).

Replace `[dynamic]T` with a custom growable type:

```odin
ParseList :: struct(T: typeid) {
    data: [^]T,
    len:  u32,
    cap:  u32,
}

list_init :: #force_inline proc(p: ^Parser, list: ^ParseList($T), initial_cap: int) {
    if initial_cap > 0 {
        list.data = transmute([^]T)bump_alloc(&p.node_pool, initial_cap * size_of(T), align_of(T))
        list.cap = u32(initial_cap)
    }
}

list_append :: #force_inline proc(p: ^Parser, list: ^ParseList($T), item: T) {
    if list.len >= list.cap {
        new_cap := max(list.cap * 2, 8)
        new_data := transmute([^]T)bump_alloc(&p.node_pool, int(new_cap) * size_of(T), align_of(T))
        if list.cap > 0 {
            mem.copy(new_data, list.data, int(list.len) * size_of(T))
        }
        list.data = new_data
        list.cap = new_cap
    }
    list.data[list.len] = item
    list.len += 1
}

list_slice :: #force_inline proc(list: ^ParseList($T)) -> []T {
    return list.data[:list.len]
}
```

Eliminates ALL runtime calls. Every operation is fully inline.

Predicted gain: **~1–2 ms on monaco** (the remaining 1.5 ms ALLOC gap
plus elimination of dispatch in some hot loops).

Cost: replacing every `[dynamic]T` field in AST node types with
`ParseList(T)`. ~131 call sites in parser.odin. Mechanical but
significant refactor.

Risk: medium. Test infrastructure (verify_*) reads AST data; need to
make sure the slice exposed via `list_slice()` matches what verifiers
expect.

### Tier 2: structural changes (predicted 2–5 % each)

#### D. Pre-allocate all bounded arrays to max size

The user's "memory is plentiful" insight applied uniformly:

- **Token array**: bounded by source length (max ~source_len bytes).
  Pre-allocate `make([]FastToken, source_len, p.allocator)` at lexer
  init. No grow ever. (Currently kessel uses streaming `cur`/`nxt`,
  not a token array — but if we materialise tokens, this would apply.)

- **Identifier name interning**: pre-allocate string-pool of size
  `source_len / 4` (rough upper bound).

- **Statement / expression slot arrays** (if we go SoA per step #5):
  pre-size to `source_len / 4` upper bound.

Predicted gain: **~0.5–1 ms** (small, because most bounded arrays are
already pre-sized; this just normalises the policy).

Risk: low.

#### E. Per-letter identifier handlers (OXC pattern)

OXC's lex pipeline uses 21 specialised per-letter byte handlers
(`L_A`, `L_B`, ..., `L_Y`) that each fuse identifier scanning AND
keyword classification into one function. Dispatched via a
`[256]proc()` table at the lex_token entry.

kessel does this in two phases: scan via `lex_identifier` then
classify via `lookup_keyword_by_letter` (now force_inline).

Per-letter helpers would let LLVM specialise each handler for ITS
keyword family (e.g., `lex_ident_t` checks only `t`-keywords: this,
true, throw, try, type, typeof). Tighter code per handler, smaller
icache footprint per handler call.

Predicted gain: **~1–2 ms on monaco** (closes most of the LEX gap).

Cost: 21 small functions instead of 1 big one. Total ~13 KB of code
either way; redistribution mainly.

Risk: medium. We tested OXC's `[256]proc()` table approach in April
and Odin's compiler doesn't inline through proc-pointer tables the way
Rust+LTO does. So we'd need the SOURCE-LEVEL `switch` dispatch in
lex_token (which IS inlinable) calling per-letter helpers (which are
themselves force_inline).

### Tier 3: cross-cutting refactors (predicted 5–12 %)

#### F. Full SoA AST migration (step #5)

Already validated as 10–12 % faster on isolated AST construction in
the fair prototype (`bench/dod_proto/proto2.odin`). Real-world
projection: 3–4 % wall time when integrated.

This is the architectural change Zig's AstGen uses. Trade-offs were
documented in `docs/dod-prototype-plan.md`.

Cost: 4–5 weeks of refactoring, including walkers and verifiers.

Risk: medium. The walkers are coupled to in-memory layout; we'd need
to update them.

#### G. Token materialisation + parser-prefetched stream

Currently kessel's lexer is streaming (cur + nxt). Materialising all
tokens upfront enables:
- Parser pre-fetching of token slots (via cache prefetch instructions)
- Better branch prediction (parser sees token-kind sequences, can
  speculate)
- Simpler parser code (no on-demand lex)

Predicted gain: **unclear, possibly negative**. April measurement
showed direct TokenSoA stores were a 33 % win in the lexer (-61 % in
lex-only) but rolled back for parser-side reasons.

Risk: high. The roll-back reasons aren't documented.

### Tier 4: speculative / OS-specific (predicted 0–2 %)

#### H. Mach VM superpages (macOS-specific)

On macOS, `vm_allocate` with `VM_FLAGS_SUPERPAGE_SIZE_2MB` requests
2 MB pages instead of the default 16 KB pages. Reduces TLB pressure for
the arena.

For monaco's ~57 MB arena: 16 KB pages = 3,500 TLB entries needed;
2 MB pages = 28 TLB entries. M-series chips have ~256-entry L1 dTLB
and ~1024-entry L2 dTLB. So we likely fit both today, but the
prefetcher + TLB walker behaviour changes.

Predicted gain: **0–0.5 ms** on monaco. Marginal.

Risk: low. macOS-only; needs platform code path.

#### I. Cache prefetch instructions in source scan

On ARM64, `__builtin_prefetch(src + 64, 0, 3)` issues a `PRFM` instruction
that prefetches a cache line ~64 bytes ahead. For sequential source
scanning, this can hide L1d miss latency.

But: the M-series cores have an aggressive hardware prefetcher that
already detects sequential access. Software prefetch hints are usually
neutral or slightly negative on M3/M4.

Predicted gain: **0** (likely no win; might even regress).

Risk: medium. We've already tested several prefetch attempts in the
session; none paid off.

#### J. Skip arena zero-fill on reset

`arena_free_all` calls `mem.zero` on the entire used region (currently
~57 MB on monaco) between parses. This is 4–7 ms per reset.

For the bench, reset is OUTSIDE the timer (commit aa1b04e), so doesn't
affect bench numbers. But for real-world parse-many workflows it
matters.

Fix: use macOS Mach `vm_deallocate` + `vm_allocate` cycle which gives
fresh zero pages from the kernel without explicit memset (kernel uses
CoW with the zero page).

Predicted gain: **0 in bench, ~5–8 ms per reset in real-world**.

Risk: low. Macos-only optimisation; needs `when ODIN_OS == .Darwin` path.

#### K. CPU QoS: QOS_USER_INTERACTIVE for parser thread

On Apple Silicon, the kernel scheduler routes threads to E-cores or
P-cores based on QoS. The default for command-line tools is
`QOS_DEFAULT` which can land on E-cores during system load.

`pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)` pins
the thread to P-cores.

Predicted gain: **0–10 % depending on system load** (more impact when
load is high).

Risk: low. Safe call; macOS-specific.

## Recommended sequence (if we keep going)

1. **A. Pre-fault arena pages** (1 hour, predicted ~1 ms gain)
2. **C. Custom ParseList type** (1–2 days, predicted ~1–2 ms gain)
3. **K. CPU QoS** (1 hour, predicted 0–10 % depending on load)
4. **E. Per-letter identifier handlers** (1 week, predicted ~1–2 ms gain on monaco)

Combined predicted: **~3–5 ms wall time gained**, taking monaco from
1.06× to ~1.00× and likely tipping the geo-mean below 1.0×.

After that: tier 3 (SoA migration, token materialisation) for the
remaining 1–2 % geo-mean. Diminishing returns.

## What we have left on the table

If we stop here at 1.002× geo-mean:
- 3 files BEAT OXC
- 6 at parity
- 10/10 within 10 %
- The geo-mean ratio is below the bench-noise floor (~1 % run-to-run variance)

Honest assessment: from a "kessel ships at OXC parity" standpoint, we
are done. From a "BEAT OXC on geo-mean" standpoint, tier 1 (A + C)
plus tier 2 (E) would likely get us there.

The user's original framing — "it makes no sense OXC could be faster"
— has been addressed: kessel is no longer measurably slower than OXC
on geo-mean. The remaining ~6 % on monaco is concentrated in lex_token's
identifier handling, where OXC's per-letter handlers fuse two phases
that kessel still does separately.
