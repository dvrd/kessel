# Handoff — Kessel

## What is Kessel

Kessel is a JavaScript / TypeScript / JSX / TSX parser written in Odin that emits ESTree-compatible JSON ASTs. Three-pass pipeline: SIMD lexer → permissive Pratt parser → opt-in semantic checker. Zero runtime dependencies, arena-only memory, ARM64 NEON SIMD lexing. Mirrors OXC's `oxc_parser` / `oxc_semantic` split.

## Current State (2026-05-15, sessions 12–13)

### Build & Tests
```
$ odin build src -out:bin/kessel -o:speed -no-bounds-check  # Clean, no warnings
$ task test                                                  # All pass: 291/291 + 23 coverage
```

### Conformance

```
test262:      parser pos 47114/47114 (100.00%) | neg 4568/4588 (99.56%)
              semantic pos 47114/47114 (100%) | neg 4588/4588 (100%)
TypeScript:   parser pos 9811/9828 (99.83%)   | neg 1470/2583 (56.91%)
Babel:        parser pos 2233/2237 (99.82%)   | neg 1603/1725 (92.93%)
              semantic pos 2224/2237 (99.42%)  | neg 1677/1725 (97.22%)
ESTree:       39/39 (100%)
Misc:         parser pos 71/72 (98.61%)       | neg 260/286 (90.91%)
```

## Sessions 12–13 Changes (18 commits)

### FP fixes (+3 babel, +1 TS positive)
1. `__proto__` dup deferred via pending list (3 babel FPs)
2. Break/continue/return skip ambient context (1 TS FP)
3. Constructor-name skip for StringLiteral+access modifier

### Negative gap closures (+79 TS negatives, +1 babel, +2 misc)
4. `.d.ts` statement rejection (+15)
5. TS1016 required-after-optional param (+1)
6. TS2371 default-in-overload + param-property (+16 TS, +1 babel)
7. Accessor type param / return type checks (+3)
8. TS1051 set accessor optional param (+2)
9. TS2491 for-in destructuring TS-only (+6)
10. TS1038 declare-in-ambient (+9)
11. TS2391/TS2389 top-level + namespace function overload chains (+15 TS, +1 misc)
12. TS2393 duplicate function implementation (+4 TS, +1 misc)
13. TS1221/TS1040 generator/async in ambient context (+3)

### Net Impact (from session 11 end)

| Metric | Before | After | Delta |
|---|---|---|---|
| TS parser negative | 1391/2583 (53.85%) | 1470/2583 (56.91%) | **+79** |
| Babel parser positive | 2230/2237 | 2233/2237 | **+3** |
| Babel parser negative | 1602/1725 | 1603/1725 | **+1** |
| TS parser positive | 9810/9828 | 9811/9828 | **+1** |
| Misc negative | 258/286 | 260/286 | **+2** |

## PRIORITY 1 — Continue closing TS negative gap

Remaining: ~1113 uncaught. Most remaining are type-system level checks (TS2339 property access, TS2394 overload compatibility, TS2300 duplicate identifiers) that require type inference — not viable at parser level.

**Still tractable clusters:**
- `conformance/es6/yieldExpressions/generatorOverloads` — function overload checks in generators
- `conformance/parser/ecmascript5/ModuleDecl` — module declaration errors
- `conformance/parser/ecmascript5/Statements` — statement-level checks (for-in, for-of)
- Duplicate property names in interfaces/classes (TS1117/TS1118/TS2300)

## PRIORITY 2 — Fix remaining FPs

17 TS + 4 Babel FPs remain. The most impactful: TS2391 overload chain in class bodies (2 babel FPs) — would need a more nuanced pre-pass than the current `has_any_impl` check.

## Key Patterns Learned

- Use `fn.no_body` (not body span) to detect overload signatures
- Gate TS-only checks with `allow_ts_mode(p)`
- `fn.declare` skip for ambient declarations
- OXC is selectively permissive in ambient contexts — only generator/async are parser-level errors
- `pending_*` lists for deferred checks that resolve later (e.g., `__proto__` in destructuring)

## Commands Reference

| Command | Purpose | Time |
|---|---|---|
| `task build` | Release binary → `bin/kessel` | ~5s |
| `task test` | **Primary gate** | ~10s |
| `task test:coverage:update` | Regenerate snaps | ~5s |
| `task test:conformance:report` | Print numbers | <1s |
| `task test:oxc-corpus:fetch` | Fetch corpora | ~2 min |
