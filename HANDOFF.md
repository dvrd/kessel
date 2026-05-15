# Handoff — Kessel

## What is Kessel

Kessel is a JavaScript / TypeScript / JSX / TSX parser written in Odin that emits ESTree-compatible JSON ASTs. Three-pass pipeline: SIMD lexer → permissive Pratt parser → opt-in semantic checker. Zero runtime dependencies, arena-only memory, ARM64 NEON SIMD lexing. Mirrors OXC's `oxc_parser` / `oxc_semantic` split.

## Current State (2026-05-15)

### Build & Tests
```
$ odin build src -out:bin/kessel -o:speed -no-bounds-check  # Clean, no warnings
$ task test                                                  # All pass: 291/291 + 23 coverage
```

### Conformance

```
test262:      parser pos 47114/47114 (100.00%) | neg 4568/4588 (99.56%)
              semantic pos 47114/47114 (100%) | neg 4588/4588 (100%)
TypeScript:   parser pos 9811/9828 (99.83%)   | neg 1477/2583 (57.18%)
Babel:        parser pos 2234/2237 (99.87%)   | neg 1604/1725 (92.99%)
              semantic pos 2224/2237 (99.42%)  | neg 1677/1725 (97.22%)
ESTree:       39/39 (100%)
Misc:         parser pos 71/72 (98.61%)       | neg 260/286 (90.91%)
```

## Net Impact (from session 11 end)

| Metric | Before | After | Delta |
|---|---|---|---|
| TS parser negative | 1391/2583 (53.85%) | 1477/2583 (57.18%) | **+86** |
| Babel parser positive | 2230/2237 (99.69%) | 2234/2237 (99.87%) | **+4** |
| Babel parser negative | 1602/1725 (92.87%) | 1604/1725 (92.99%) | **+2** |
| TS parser positive | 9810/9828 | 9811/9828 | **+1** |
| Misc negative | 258/286 | 260/286 | **+2** |

## Remaining FPs

### Babel FPs (3)
- `members-with-modifier-names` / `method-with-newline-without-body` — TS2391 class overload pre-pass trade-off
- `parameter-properties` — `?` + initializer (removing loses 7 negatives)

### TS FPs (17)
- Lexical declaration cluster (3), multi-file async generator (4), error recovery singles (5), source-type/ambient (3), decorators (2)

## Checks Added (17 parser-level checks across sessions 12–15)

1. `__proto__` pending list for destructuring
2. Break/continue/return ambient skip
3. `.d.ts` statement rejection
4. TS1016 required-after-optional
5. TS2371 default-in-overload + param-property
6. Accessor type param / return type
7. TS1051 set accessor optional param
8. TS2491 for-in destructuring (TS-only)
9. TS1038 declare-in-ambient
10. TS2391/TS2389 function overload chains (top-level + namespace)
11. TS2393 duplicate function implementation
12. TS1221/TS1040 generator/async in ambient
13. `.d.ts` namespace `in_ambient` propagation
14. TS1319 export-default in namespace
15. TS2669 declare-global scope validation
16. CommonJS using/await-using at top level
17. Constructor-name StringLiteral+access skip

## What's Left

Most remaining ~1106 uncaught TS negatives are type-system checks (TS2394, TS2339, TS2300) requiring type inference. The class overload pre-pass balances FP prevention vs. catches.

## Commands

| Command | Purpose |
|---|---|
| `task build` | Release binary |
| `task test` | Primary gate |
| `task test:coverage:update` | Regenerate snaps |
| `task test:conformance:report` | Print numbers |
| `task test:oxc-corpus:fetch` | Fetch corpora |
