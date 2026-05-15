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
TypeScript:   parser pos 9811/9828 (99.83%)   | neg 1495/2583 (57.88%)
Babel:        parser pos 2234/2237 (99.87%)   | neg 1604/1725 (92.99%)
              semantic pos 2224/2237 (99.42%)  | neg 1677/1725 (97.22%)
ESTree:       39/39 (100%)
Misc:         parser pos 71/72 (98.61%)       | neg 261/286 (91.26%)
```

## Net Impact (from session 11 end)

| Metric | Before | After | Delta |
|---|---|---|---|
| TS parser negative | 1391/2583 (53.85%) | 1495/2583 (57.88%) | **+104** |
| Babel parser positive | 2230/2237 (99.69%) | 2234/2237 (99.87%) | **+4** |
| Babel parser negative | 1602/1725 (92.87%) | 1604/1725 (92.99%) | **+2** |
| TS parser positive | 9810/9828 | 9811/9828 | **+1** |
| Misc negative | 258/286 | 261/286 | **+3** |

## Checks Added (20 parser-level checks)

1. `__proto__` pending list for destructuring (+3 babel FPs)
2. Break/continue/return ambient skip (+1 TS FP)
3. `.d.ts` statement rejection (+15 TS neg)
4. TS1016 required-after-optional (+1 TS neg)
5. TS2371 default-in-overload + param-property (+16 TS, +1 babel neg)
6. Accessor type param / return type (+3 TS neg)
7. TS1051 set accessor optional param (+2 TS neg)
8. TS2491 for-in destructuring TS-only (+6 TS neg)
9. TS1038 declare-in-ambient (+9 TS neg)
10. TS2391/TS2389 function overload chains (+15 TS, +1 misc neg)
11. TS2393 duplicate function impl (+4 TS, +1 misc neg)
12. TS1221/TS1040 generator/async in ambient (+3 TS neg)
13. .d.ts namespace in_ambient propagation (+1 TS neg)
14. TS1319 export-default in namespace (+4 TS, +1 babel neg)
15. TS2669 declare-global scope (+2 TS neg)
16. CommonJS using/await-using skip (+1 babel FP)
17. Constructor-name StringLiteral+access skip
18. TS2309 export-assignment conflicts (+14 TS, +1 misc neg)
19. TS2384 overload ambient mismatch (+4 TS neg)
20. (attempted class-name-required, class overload pre-pass refinement — reverted)

## Remaining

- **3 Babel FPs**: members-with-modifier-names, method-with-newline-without-body, parameter-properties
- **17 TS FPs**: lexical decl cluster (3), async generator multi-file (4), error recovery (5), source-type (3), decorators (2)
- **~1088 uncaught TS negatives**: mostly type-system (TS2394/2339/2300) — not viable at parser level

## Commands

| Command | Purpose |
|---|---|
| `task build` | Release binary |
| `task test` | Primary gate |
| `task test:coverage:update` | Regenerate snaps |
| `task test:conformance:report` | Print numbers |
| `task test:oxc-corpus:fetch` | Fetch corpora |
