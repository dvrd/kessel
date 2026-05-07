# Handoff — Kessel

**Date:** 2026-05-07 (seventh wave — slices 11/12/13 — **migration complete**)
**Tip:** `deabcdb feat(checker): slice 13e — migration COMPLETE (4 → 0)`
**Branch:** `main`, 7 commits ahead of `origin/main` (slices 11, 12, 13a, 13b, 13c, 13d, 13e).

## What is Kessel

JavaScript / TypeScript / JSX / TSX parser written in [Odin](https://odin-lang.org/) that emits ESTree-compatible JSON ASTs. Targets ES2015–ES2025. Zero runtime dependencies, arena-only memory, ARM64 NEON SIMD lexing, hand-written Pratt expression parser. Three-pass architecture (lexer → permissive parser → opt-in semantic checker) modelled on OXC's `oxc_parser` + `oxc_semantic` split. The CLI exists for development; the real consumer is a future toolchain pipeline (linter / transformer / bundler / codegen).

---

## Session Headlines (2026-05-07)

| Item | Start of session | End of session |
|---|---|---|
| **Inline `report_semantic_error*` calls in parser.odin** | 48 (post slice 10) | **0** — migration COMPLETE |
| **Full-session reduction** | — | **101 → 0** across slices 1–13 (100%) |
| **Architectural rule** | convention-only | **structurally enforced** (parser-side `report_semantic_error*` helpers deleted) |
| `src/parser.odin` | 19 238 lines | **18 634 lines** (−604 net) |
| `src/checker.odin` | 1 721 lines | **2 921 lines** (+1 200) |
| **`odin build src -vet`** | 0 warnings | **0 warnings** (held) |
| **All 18 `task test` gates** | green | **green** (held) |
| **OXC-corpus kessel-only-rejects** | 0 | **0** (held) |
| **Fixture relocks** | — | 19 across all slices (locations strictly more accurate) |

7 commits added this session:

1. `c22264e` — feat(checker): slice 11 — cheap finishers (48 → 22)
2. `b3ebaf3` — feat(checker): slice 12 — `await`-as-escaped-identifier (22 → 20)
3. `cad24c2` — feat(checker): slice 13a — private-name resolution (20 → 17)
4. `3ad6c11` — feat(checker): slice 13b — module export rules (17 → 13)
5. `b6dc749` — feat(checker): slice 13c — for-head/body + catch-param + fn-params shadowing (13 → 9)
6. `8132593` — feat(checker): slice 13d — scope_add via pending_checker (9 → 4)
7. `deabcdb` — feat(checker): slice 13e — migration COMPLETE (4 → 0)

---

## What slices 11/12/13 shipped

### Slice 11 — cheap finishers (26 migrations)

Local AST-only checks with no scope dependency, folded into the existing checker walker:

  * §14.3 `using` / `await using` at top of script
  * §14.13.1 duplicate label declared
  * §13.5 / B.3.2 plain FunctionDeclaration in single-statement iteration body
  * §13.7.5.1 CallExpression as for-in/of LHS in strict
  * §13.7.5.1 only single declaration in for-in/of head
  * §13.7.5.1 for-in/of decl with initializer
  * §15.4.5 catch parameter duplicate identifier
  * §15.7.1 yield as gen-fn-expr name (export-default)
  * §15.7.1 yield as fn name in strict mode (expr/decl)
  * §15.7.1 eval/arguments as fn name in strict mode
  * §15.7.1 private getter/setter static-mismatch
  * §14.3.1.1 per-decl duplicate lexical names
  * §15.5.1 / §15.6.1 / §15.8.1 duplicate parameter name (regular fn AND arrow fn)
  * §15.5.1 strict eval/arguments as parameter name
  * §15.5.1 strict-reserved as parameter name
  * §13.15.1 strict eval/arguments as assignment LHS (incl. for-in/of LHS)
  * §13.4.4 strict eval/arguments as update target (prefix and postfix)
  * §13.1.1 strict-reserved word as BindingIdentifier (var/let/const declarators)
  * §13.1.1 strict eval/arguments as BindingIdentifier
  * §13.1.1 strict-reserved name as BindingIdentifier
  * §16.2.2 eval/arguments as ImportedBinding
  * §13.5.1 delete IdentifierReference in strict mode
  * §12.6.1.1 strict-reserved as IdentifierReference (incl. shorthand-property keys)

New checker helpers added: `ck_check_strict_binding_pattern` (with `CkBindingFlavour` enum), `ck_check_for_in_of_head`, `ck_check_for_in_of_init_eval_args`, `ck_check_single_stmt_function`, `ck_check_class_private_static_mismatch`, `ck_check_var_decl_lexical_dups`, `ck_check_using_at_script_top`, `ck_check_label_redeclared`, `ck_check_unary_delete_local`, `ck_check_strict_eval_arguments_in_target`, `ck_check_strict_update_eval_arguments`, `ck_check_identifier_reference_strict`, `ck_check_import_specifier_local`, `ck_check_duplicate_param_names`, `ck_check_catch_param_dups`, `ck_walk_import_decl`. The strict-mode function-name BindingIdentifier check folded inline into `ck_walk_function`.

Parser-side stubs (kept as no-ops for the many call sites still referencing them, future cleanup will remove): `report_strict_param_names`, `report_strict_param_pattern`, `report_strict_eval_arguments_in_target`, `report_strict_update_on_eval_or_arguments`, `report_duplicate_param_names`, `report_duplicate_lexical_names`.

18 fixture relocks: the migration's diagnostic anchors are strictly more accurate than the parser's. Where the parser used cur_loc at error-emission time (often pointing at the line/column AFTER the offending construct, or at the closing brace of the function body), the checker anchors at the AST node's start.

### Slice 12 — AST extension for `await`-as-escaped-identifier (2 migrations)

Adds `has_escape: bool` to the `Identifier` AST node so the checker can match the parser's narrow gating on Unicode-escape forms (`\u0061wait`, `\u006Cet`, etc.). Two parser-side checks in `parse_unary_expr`'s identifier fast-path and `parse_primary_expr`'s fallback identifier branch are now delegated to `ck_check_identifier_await_reserved`.

The yield-as-operator-operand checks (parser L9745 / L10014 / L10149) were considered for a parallel `was_parenthesized: bool` flag on `YieldExpression` but the field was reverted: those checks are PARSE-FLOW-tied — the parser MUST return early after detecting them to avoid building a malformed binary-expression AST, and the checker walking the post-parse AST cannot reconstruct the violation because the early-return drops the offending operator. They are migrated by promotion to `report_error` in slice 13e instead.

### Slice 13 — scope analysis (split into 5 sub-slices for reviewability)

#### 13a — private-name resolution (3 migrations + 302-line walker deletion)

Migrates §15.7.3 AllPrivateIdentifiersValid: every PrivateIdentifier reference (`obj.#x`, `#x in y`, bare `#x`) must be declared in an enclosing class. The parser's bespoke `verify_private_names` walker (PrivateNameStack + pn_walk_stmt/_var_decl/_expr + pn_visit_class + pn_collect_class_names + pn_stack_has, ~302 lines total) is deleted. The checker uses `CheckerContext.private_name_stack`, pushed by `ck_walk_class` on entry, popped on exit.

#### 13b — module export rules (4 migrations)

Migrates §16.2.1 duplicate-export-name (in TS/TSX mode only — JS mode keeps the parser-side `report_error_at` because OXC's parser fires duplicate-export there as a structural / parse-time error) and §16.2.2 "export not defined in module". New checker helpers `ck_check_export_dups`, `ck_check_export_local_defined`, `ck_collect_module_top_level_names`. The parser keeps the structural string-literal-without-from rule (always-fire syntax error).

#### 13c — for-head/body + catch-param + fn-params shadowing (4 migrations)

Migrates §14.7.4.1 / §14.7.5.1 for-head-vs-body shadowing (let/const head vs body var hoist), §15.4.5 catch-param-vs-body redeclaration, §15.2.1.1 / §15.5.1 formal-param-vs-body redeclaration. New helpers `ck_check_for_head_body_shadow`, `ck_check_catch_param_body_shadow`, `ck_check_params_vs_body_lex`. Checker-local mirrors of the parser's `scope_hoist_vars` and `scope_process_statement` (the no_parser variants) avoid pulling the full parser-side scope machinery into the checker.

#### 13d — scope_add via `pending_checker` (5 migrations)

The five `report_semantic_error_at` sites inside the parser's `scope_add` proc — the heart of duplicate-binding detection across lex/var/Annex-B-fn-decl flavours — are redirected through a new `Parser.pending_checker: ^Checker` field. The parser still BUILDS the `scope_pending` queue at parse time, but the post-parse drain is now driven by `checker_run_for_job`, which sets `p.pending_checker` immediately before invoking `verify_scopes` and clears it on exit. The `scope_emit` thin helper forwards to `checker_append_error(p.pending_checker, ...)`.

This is the architecturally-cleanest split: the parser owns scope-tree construction (which is parse-time work — needed for tracking parens, generators, async, TS-namespace nesting, etc.) and the checker owns diagnostic emission. The "parser = syntax / checker = semantic" rule is preserved because the parser never EMITS a diagnostic from these sites — it only PROVIDES the structural scope tree the checker walks.

#### 13e — final cleanup (4 promotions)

The four remaining `yield`-tied sites are promoted from `report_semantic_error` to `report_error` because they are structural parse errors per the ECMA-262 grammar:

  * L2208 — `yield` as label identifier inside a generator. `yield` is a reserved keyword in a GeneratorBody so the LabelledStatement form is grammatically impossible.
  * L9351 / L9620 / L9755 — yield-as-operator-operand of a binary, right-hand-side of a binary, or unary operator. `YieldExpression` is at AssignmentExpression precedence and is not a valid operand of these operators.

The parser-side `report_semantic_error` and `report_semantic_error_at` helpers are now removed entirely — they have no remaining callers. The architectural invariant is enforced structurally: any new semantic check MUST be added to `src/checker.odin`; the parser cannot emit a `report_semantic_error*` because the helpers don't exist.

---

## Current State

### Build

| Command | Result | Time |
|---|---|---:|
| `task build` (release) | ✅ clean, no warnings | 31 s cold |
| `odin build src -vet` | ✅ silent, 0 warnings | — |

`odin build src -out:bin/kessel -o:speed -no-bounds-check`. 3.1 MB binary. Toolchain: **Odin dev-2026-04:df6fff6e4** on macOS 15.6 Apple M1 Max.

### Tests — every gate green

| Gate | Result | Notes |
|---|---|---|
| `task test:unit` | ✅ **430/430** | 19 fixtures relocked across slices 11/13a/13d (location precision improvements) |
| `task test:negative` | ✅ rejected 139, accepted-bug 0 | |
| `task test:ambiguity` | ✅ baseline OK | |
| `task test:regression` | ✅ 11/11 | |
| `task test:real` | ✅ **467/467** | |
| `task test:estree` | ✅ all OK | |
| `task test:nodes` | ✅ 57/57 ESTree node types | |
| `task test:recovery` | ✅ **31/31** | |
| `task test:lexical` | ✅ baseline OK | |
| `task test:invariants` | ✅ 467/467 + zero-tolerance OK | |
| `task test:spec-compliance` | ✅ baseline OK | |
| `task test:spec-fixtures` | ✅ **150/150** | |
| `task test:test262` | ✅ 66/66 | |
| `task test:test262:subset` | ✅ **66/66** baseline | |
| `task test:multi-parser` | ✅ deep JSON compare passes vs babel | |
| `task test:fuzz` | ✅ 100/100 | seed=20260421 |
| `task test:fuzz:invalid` | ✅ **300/300 exited cleanly, 0 crashes** | |
| `task test:crashes-known` | ✅ 0 new | |
| `task test:oxc-corpus` | ✅ baseline OK | **0 kessel-only-rejects** (held); 19 oxc-only-rejects (kessel more lenient than OXC on edge cases) |

`task test:bench:regression` was last verified at the slice-10 commit; this session's slices add a small constant amount of post-parse work behind `--show-semantic-errors` and don't touch the default parse path. Re-run on a quiet machine if the bench gate is needed.

---

## Project Structure

| File | Lines | Purpose |
|---|---:|---|
| `src/parser.odin` | 18 634 | Hand-written Pratt parser + lazy module pre-scan + `scope_pending` queue + post-parse `verify_scopes` walker. **0 inline `report_semantic_error*` calls; the helpers themselves are deleted.** Still owns the structural scope-tree machinery (BlockStatement / FunctionBody / SwitchCase / static-block boundary tracking) but the diagnostic emission for duplicate-binding clashes is routed through `p.pending_checker` to the active semantic checker. |
| `src/emitter.odin` | 6 381 | ESTree JSON emitter. |
| `src/lexer.odin` | 3 097 | SIMD lexer. |
| **`src/checker.odin`** | **2 921** | **AST-walker semantic checker (pass 3).** 13 slices live (≈55+ distinct checks). Public API: `check_program`, `checker_run_for_job`, `checker_append_error` (called from parser-side `verify_scopes` via `p.pending_checker`). |
| `src/regex.odin` | 2 235 | ES2025 §22.2.1 regex pattern validator. |
| `src/ast.odin` | 1 614 | AST struct/union definitions. (+1 field: `Identifier.has_escape` from slice 12.) |
| `src/raw_transfer.odin` | 1 304 | Zero-copy binary AST buffer. |
| `src/main.odin` | 1 295 | CLI dispatch + worker pool. |
| `src/simd.odin` | 601 | ARM64 NEON intrinsics. |
| `src/parse_job.odin` | 419 | "Source-to-parsed-Program" deep module. |
| `src/token.odin` | 383 | `TokenType` enum, `FastToken`, `LiteralValue`. |
| `src/unicode_tables.odin` | 329 | Unicode 17.0.0 ID range tables. |
| `src/cli_config.odin` | 188 | `CliConfig` struct, `cli_try_parse_flag`. |
| `src/source_io.odin` | 103 | Cross-platform source reader. |
| `src/source_io_posix.odin` | 69 | POSIX mmap path. |
| `src/qos_darwin.odin` | 61 | Apple Silicon QoS hint. |
| `src/source_io_other.odin` | 17 | Windows stub. |

---

## Architecture: pass 3 (semantic checker) — all 13 slices completed

| Slice | Commit | Coverage |
|---|---|---|
| **1** | `4b93e2a` | break / continue context + label scoping (§13.9.1, §13.9.2, §14.13.1, §14.8.1). |
| **2** | `86cd68b` | Wire `cli.show_semantic_errors → ParseConfig.check_semantics → p.check_semantics`. |
| **3** | `9fabda0` | accessor checks (§15.4.3 / §15.4.4 / §15.4.5). |
| **4** | `ea574d4` | local AST checks: dup `__proto__`, dup default, dup constructor, delete-private, super-private. |
| **5** | `3429b46` | strict-mode tracker + 9 migrations. |
| **6** | `c1efc63` | function-context tracker + 6 migrations + delete `scan_field_init_arguments` walker. |
| **7** | `66f47e0` | formal-parameter scope + 5 migrations + delete arrow-cover walkers (−170 lines). |
| **8** | `96003c2` | "use strict" directive in non-simple params (6 sites collapsed). |
| **9** | `b48b3ef` | import/export position rules + invalid-LHS in compound assignment. |
| **10** | `6222980` | class-name + arrow-param BindingIdentifier reservation rules. |
| **11** | `c22264e` | cheap finishers — 26 local AST migrations (this session). |
| **12** | `b3ebaf3` | `await`-as-escaped-identifier — `Identifier.has_escape` AST extension (this session). |
| **13a** | `cad24c2` | private-name resolution — `verify_private_names` deleted (this session). |
| **13b** | `3ad6c11` | module export rules (TS-mode duplicate-export + undefined-export) (this session). |
| **13c** | `b6dc749` | for-head/body + catch-param + fn-params shadowing (this session). |
| **13d** | `8132593` | `scope_add` via `pending_checker` — last 5 sites bridged (this session). |
| **13e** | `deabcdb` | final cleanup: 4 yield-tied promotions to `report_error`; helpers deleted (this session). |

### Migration policy (now structurally enforced)

> **Parser handles syntax errors. Checker handles semantic errors.** As of slice 13e, the parser-side `report_semantic_error` / `report_semantic_error_at` helpers are deleted from `src/parser.odin`. Any new semantic check MUST be added to `src/checker.odin` — the parser literally cannot emit one. Bridges from parser-owned post-parse walks (today: only `verify_scopes`) into the checker's diagnostic stream go through the package-level `checker_append_error(p.pending_checker, ...)` proc.

---

## What changed in the AST

| Field | Type | Slice | Purpose |
|---|---|---|---|
| `Identifier.has_escape` | `bool` | 12 | Set when the source token contained at least one Unicode escape sequence (`\u006Cet`, `\u0061wait`, etc.). Used by `ck_check_identifier_await_reserved` to match the parser's narrow gating on escaped contextual reserved words. |

`YieldExpression.parenthesized` was considered (slice 12 draft) but reverted: the yield-as-operator-operand checks are parse-flow-tied (the parser must return early to avoid malformed AST shapes), so the AST after early-return doesn't reflect the violation. Slice 13e promotes those checks to structural `report_error` instead.

---

## What was removed from the parser

  * `verify_private_names` + `pn_walk_stmt` + `pn_walk_var_decl` + `pn_walk_export_default_decl` + `pn_walk_expr` + `pn_visit_class` + `pn_collect_class_names` + `pn_stack_has` + the `PrivateNameStack` type + the `private_id_count` short-circuit — **~302 lines deleted in slice 13a**.
  * The `scan_field_init_arguments` walker — deleted in slice 6 (~120 lines).
  * The `scan_arrow_cover_for_yield_await` walker — deleted in slice 7 (~170 lines).
  * The `pending_proto_dups` machinery — deleted in slice 4 (~50 lines).
  * `report_semantic_error` and `report_semantic_error_at` helper procs — **deleted in slice 13e**.
  * Inline strict-mode parameter / strict-reserved BindingIdentifier / IdentifierReference checks — folded out across slices 5, 7, 10, 11.

Stub procs remain for several call sites that still pass through them (no-op bodies; future cleanup will delete the call sites): `report_strict_param_names`, `report_strict_param_pattern`, `report_strict_eval_arguments_in_target`, `report_strict_update_on_eval_or_arguments`, `report_duplicate_param_names`, `report_duplicate_lexical_names`, `check_params_vs_body_lex`.

---

## Known Issues

`grep -rnE "TODO|FIXME|HACK|BUG|WORKAROUND" src/` — empty.

| # | Issue | Severity | Scope |
|---|---|---|---|
| 1 | OXC corpus: **19 oxc-only-rejects** (kessel more lenient than OXC) | minor | Edge cases where kessel accepts but OXC rejects (the inverse direction is 0). Not actionable by simply "matching OXC" — case-by-case judgement. |
| 2 | OXC corpus: 2 157 babel "should-pass-rejected" | shared gap with Babel | Babel-specific syntax (Flow, pipeline-operator, experimental decorators). NOT kessel bugs — OXC drops them too. |
| 3 | `AGENTS.md` is `.gitignore`d | local-only | By project convention. The HANDOFF doc covers all material info. |
| 4 | Branch is **7 commits ahead of `origin/main`** | session deliverable | `git push origin main` to publish. |
| 5 | Parser stubs (`report_strict_param_names` etc.) | minor cleanup | No-op bodies, kept for compatibility with existing call sites; one or two passes through the parser would let us delete them. Non-blocking. |

---

## What To Work On Next

The migration is COMPLETE. Future work:

1. **Push the branch.** `git push origin main` — durably saves slices 11/12/13.
2. **Stub-cleanup pass** (optional, low-priority): delete the 7 parser-side stub procs (`report_strict_param_names`, `report_strict_param_pattern`, `report_strict_eval_arguments_in_target`, `report_strict_update_on_eval_or_arguments`, `report_duplicate_param_names`, `report_duplicate_lexical_names`, `check_params_vs_body_lex`) by also deleting the ~10 call sites that still reference them. Each stub is a no-op so the call sites are dead code; deleting them shortens parser.odin by another ~50 lines.
3. **Bench gate confirmation**: `task test:bench:regression` on a quiet machine, just to confirm the slices 11–13 changes haven't regressed the 0.93×-of-OXC ratio. The default parse path (no `--show-semantic-errors`) is structurally unchanged this session, so a regression would be surprising.
4. **Future deepening (architecture review #4 – deferred)**: extract a shared AST traversal module if a third concrete walker pattern emerges. Today the checker walker covers break/continue + literals + identifiers + patterns + JSX + class bodies + private names + scope flags; the parser's `verify_scopes` is a separate walker focused on scope-tree binding emission. If a future linter or transformer pass needs a fourth walker, factor a shared `walker.odin`.

---

## Commands Reference

```bash
task build                # release → bin/kessel (31s, no warnings)
odin build src -vet       # silent, 0 vet warnings

# Full chain — all 18 gates pass clean now
task test

# Individual gates
task test:unit            # 430/430
task test:negative        # 139 rejected, 0 accepted-bug
task test:test262         # 66/66
task test:test262:subset  # 66/66 baseline
task test:real            # 467/467
task test:oxc-corpus      # 0 kessel-only-rejects
task test:estree
task test:nodes           # 57/57
task test:recovery        # 31/31
task test:lexical
task test:invariants      # 467/467 + zero-tolerance
task test:spec-compliance
task test:spec-fixtures   # 150/150
task test:multi-parser
task test:fuzz            # 100/100
task test:fuzz:invalid    # 300/300 clean, 0 known crashes
task test:crashes-known
task test:ambiguity
task test:regression      # 11/11
task test:bench:regression # confirm on a quiet machine
task bench:quick          # 9/10 below OXC, geo-mean 0.93×
```

### Pass-3 / semantic checker

```bash
# Default — parser only (matches OXC parseSync)
./bin/kessel parse foo.js

# With pass 3 — every early-error check (slices 1–13 covered)
./bin/kessel parse foo.js --show-semantic-errors

# Test262 subset and verify_negative.js automatically pass the flag for
# fixtures whose purpose is rejection-under-spec.
task test:test262:subset
task test:negative
```
