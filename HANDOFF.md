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
TypeScript:   parser pos 9811/9828 (99.83%)   | neg 1463/2583 (56.64%)
Babel:        parser pos 2233/2237 (99.82%)   | neg 1603/1725 (92.93%)
              semantic pos 2224/2237 (99.42%)  | neg 1677/1725 (97.22%)
ESTree:       39/39 (100%)
Misc:         parser pos 71/72 (98.61%)       | neg 259/286 (90.56%)
```

## Sessions 12–13 Changes (16 commits)

### FP fixes (+3 babel, +1 TS positive)
1. `__proto__` dup deferred via pending list (3 babel FPs)
2. Break/continue/return skip ambient context (1 TS FP)
3. Constructor-name skip for StringLiteral+access modifier

### Negative gap closures (+72 TS negatives, +1 babel, +1 misc)
4. `.d.ts` statement rejection (+15)
5. TS1016 required-after-optional param (+1)
6. TS2371 default-in-overload + param-property (+16 TS, +1 babel)
7. Accessor type param / return type checks (+3)
8. TS1051 set accessor optional param (+2)
9. TS2491 for-in destructuring TS-only (+6)
10. TS1038 declare-in-ambient (+9)
11. TS2391/TS2389 top-level + namespace function overload chains (+15 TS, +1 misc)

### Net Impact (from session 11 end)

| Metric | Before | After | Delta |
|---|---|---|---|
| TS parser negative | 1391/2583 (53.85%) | 1463/2583 (56.64%) | **+72** |
| Babel parser positive | 2230/2237 | 2233/2237 | **+3** |
| Babel parser negative | 1602/1725 | 1603/1725 | **+1** |
| TS parser positive | 9810/9828 | 9811/9828 | **+1** |
| Misc negative | 258/286 | 259/286 | **+1** |

## PRIORITY 1 — Continue closing TS negative gap

Remaining: ~1120 uncaught negatives. Biggest clusters:
- `compiler/*` (~575): diverse — function overloads (TS2394 type compat, can't do at parser), duplicate decls, collision checks
- `conformance/es6/*` (~92): ES6 feature checks
- `conformance/types/*` (~66): Type system (indexers, conditional types, mapped types)
- `conformance/parser/*` (~55): Statements, StrictMode, ModuleDecl, FunctionDecl
- `conformance/expressions/*` (~56): Binary ops, type guards, unary ops
- `conformance/classes/*` (~55): Members, constructors, property declarations
- `conformance/jsdoc/*` (~49): JSDoc checks — low priority
- `conformance/salsa/*` (~19): JS analysis — hard

**Approach:** Keep migrating checker→parser for TS-specific checks. Key patterns:
- The `fn.no_body` flag (not body span) reliably detects overload signatures
- Gate TS-only checks with `allow_ts_mode(p)` to preserve test262
- `fn.declare` skip for ambient declarations

## PRIORITY 2 — Fix remaining FPs

17 TS + 4 Babel FPs remain (unchanged from session 12). All require either complex error recovery or trade negative regressions.

## Commands Reference

| Command | Purpose | Time |
|---|---|---|
| `task build` | Release binary → `bin/kessel` | ~5s |
| `task test` | **Primary gate** — coverage snap gate + 291 unit fixtures | ~10s |
| `task test:coverage:update` | Regenerate all snap baselines | ~5s |
| `task test:conformance:report` | Print conformance numbers from snaps | <1s |
| `task test:oxc-corpus:fetch` | Fetch all OXC corpora | ~2 min |
