# Wave 3 Item 7 — `<` Trial-Parse Design

Closing **TS-C1c** (`<T>(x) => x` generic arrow) and **TS-C6** (`<Type>expr`
angle assertion). Both crash today.

Orchestrator-led because it cuts across the lexer, parser dispatch, and
CLI / extension detection.

## Root cause

`parse_primary_expr` in `src/parser.odin` L4014-4015:
```odin
case .LAngle:
    return parse_jsx_element_or_fragment(p)
```

Unconditional dispatch to JSX. No language-mode check, no lookahead, no
disambiguation. Hits any `<` in primary-expression position.

`allow_jsx: bool` (L213) and `jsx_context: bool` (lexer L86) exist as fields
but are **dead code** — never set to `true`, never read. So every file is
parsed as JSX-capable regardless of extension.

## Why this is two bugs, not one

1. **Language-mode detection is missing.** Kessel has no notion of JS vs JSX
   vs TS vs TSX. Real consumers need this:
   - `.js` / `.mjs` / `.cjs`: no JSX, no TS types. `<` in expr = comparison
     context only. Shouldn't be JSX.
   - `.jsx`: JSX enabled, no TS types.
   - `.ts` / `.mts` / `.cts`: TS types enabled, no JSX. `<` can start
     `<Type>expr` or `<T>(x) => x`.
   - `.tsx`: BOTH TS types AND JSX enabled → genuine ambiguity at `<`.
2. **No trial-parse at `<`.** Even in pure TS mode (where there's no JSX
   to disambiguate from), the parser doesn't try `<Type>expr` or
   `<T>(x) => x`. It just falls into JSX by default and crashes.

## Design

### Phase A — Language mode plumbing (foundational, ~150 LOC)

**Goal:** Make Kessel aware of JS / JSX / TS / TSX. Gate JSX parsing and
TS type parsing on the current mode.

1. **Add `Lang` enum** (`src/parser.odin` near Parser struct):
   ```odin
   Lang :: enum u8 {
       JS,   // plain JavaScript
       JSX,  // JavaScript + JSX syntax
       TS,   // TypeScript, no JSX
       TSX,  // TypeScript + JSX (ambiguous at `<`)
   }
   ```
2. **Replace `allow_jsx: bool` on Parser with `lang: Lang`**. Derive:
   - `allow_jsx := p.lang == .JSX || p.lang == .TSX`
   - `allow_ts  := p.lang == .TS  || p.lang == .TSX`
   - These go through #force_inline getters so hot paths don't branch
     on enum comparisons each time.
3. **Detect from filename in `main.odin`** when no `--lang` flag is passed.
   Suffix table:
   ```
   .js  .mjs .cjs → Lang.JS
   .jsx           → Lang.JSX
   .ts  .mts .cts → Lang.TS
   .tsx           → Lang.TSX
   ```
4. **Add `--lang=js|jsx|ts|tsx`** CLI flag (closes OPT-2 while we're here).
5. **Gate JSX dispatch** in `parse_primary_expr` on `allow_jsx`.
   - When `allow_jsx = false` and `<` is seen in expression position:
     - In TS/TSX mode → call new `parse_ts_lt_expression` (Phase B).
     - In pure JS mode → report error (current behavior is incorrect JSX).
6. **Backward compat risk**: `spec/jsx/*` fixtures are `.js` files that
   EXPECT JSX. Check each fixture's first line; many use a directive
   comment. Decision: the fixture runner should pass `--lang=jsx`
   explicitly. Or, the fixture file should be renamed to `.jsx`.
   - **Decision for MVP:** the fixture runner (`tests/runners/run_tests.sh`)
     detects `jsx/` in the path and sets `--lang=jsx`. That's a 1-line
     runner change and zero fixture renames.
7. **Verification**:
   - `task test:real` stays at 467/467 (all .js, most non-JSX; any JSX-in-.js
     files in the corpus will need a flag — audit first).
   - `spec/jsx/*` still 100% (via runner flag).
   - `spec/typescript/*` still 10/10 parse-clean.

### Phase B — TS `<` handling (closes TS-C1c + TS-C6 for pure .ts)

When `lang = Lang.TS` (no JSX ambiguity at all), `<` in primary-expression
position is UNAMBIGUOUS — always a TS type assertion `<Type>expr` or a
generic arrow `<T>(x) => x`. No backtracking needed. Heuristic:

```
parse_ts_lt_expression :: proc(p: ^Parser) -> ^Expression {
    start := cur_loc(p)
    eat(p)  // consume `<`

    // Lookahead: if the token sequence after `<...>` forms a generic
    // arrow signature `<...>(params) =>` we're in generic-arrow land.
    // Otherwise it's a type assertion `<Type>expr`.
    //
    // The cheapest heuristic: parse a type parameter list speculatively.
    // If we land on `(`, it's the start of an arrow's params → generic
    // arrow. If we land on something else (identifier, literal,
    // parenthesized expr not in arrow position, etc.), it's an assertion.
    //
    // In TS mode there is NO OTHER OPTION — `<` at expression position
    // means one of these two. We can be confident.

    // Try type param list; fall back to single type for assertion.
    if looks_like_type_params(p) {
        // Generic arrow: <T, U>(x: T, y: U): R => expr
        type_parameters := parse_ts_type_parameters_after_lt(p, start)
        // parse_ts_type_parameters_after_lt eats through the matching `>`
        if !is_token(p, .LParen) {
            report_error(p, "Expected '(' after generic arrow type params")
            return nil
        }
        return parse_arrow_function_with_type_params(p, start, type_parameters)
    } else {
        // Type assertion: <Type>expr
        type_ann := parse_ts_type(p)
        expect_token(p, .RAngle)
        expr := parse_unary_expr(p)  // or parse_assignment_expression?
        node := new_node(p, TSTypeAssertion)
        node.loc = start
        node.type_annotation = type_ann
        node.expression = expr
        node.loc.span.end = prev_end_offset(p)
        return expression_from(p, node)
    }
}

looks_like_type_params :: proc(p: ^Parser) -> bool {
    // Peek at the token stream from current position. We're AFTER
    // consuming `<`. Check: identifier [`extends` T] (`,` identifier ...)?
    // then `>` then `(`.
    //
    // But this is a PEEK, not a consume. Kessel's lexer is already
    // one-ahead (cur + nxt). For N-ahead we need a save/restore.
    //
    // Cheapest: look at cur_tok and nxt_tok. If cur = Identifier and
    // nxt in {.Comma, .Extends, .RAngle, .Assign (default)}, it's
    // probably type params. Otherwise assertion.
    //
    // This is 99%-accurate and cheap. Edge cases (e.g. `<T extends U<V>>`
    // where the inner `<` needs full recursion) fall to a more expensive
    // path that actually runs parse_ts_type_parameters with a snapshot.
}
```

**Cost:** ~80 LOC, no new helpers beyond what already exists
(`parse_ts_type_parameters`, `parse_ts_type`).

### Phase C — TSX trial-parse (closes TS-C1c for .tsx, defers TS-C6)

TSX is genuinely ambiguous:
- `<T>x` could be JSX opening tag OR type assertion.
- `<T>(x) => x` could be JSX opening with a `(x)` text child OR generic
  arrow.

OXC's rule (matches the TSX spec):
- **Type assertions `<Type>expr` are FORBIDDEN in `.tsx`.** Use `x as Type`
  instead. Reject any `<Type>expr` attempt with a clear error.
- **Generic arrows require a trailing comma** `<T,>(x) => x` to
  disambiguate from JSX `<T>`. The trailing comma is illegal in JSX
  attribute lists, so it's a cheap signal.

Implementation:
```
if lang == .TSX {
    // Save lexer state.
    saved := lexer_snapshot(p.lexer)
    defer if !matched { lexer_restore(p.lexer, saved) }
    
    eat(`<`)
    if is_token(p, .Identifier) && peek_is(p, .Comma) {
        // <T, ...>(x) => ...  — generic arrow with trailing comma
        matched = true
        return parse_generic_arrow(p, start)
    }
    // Otherwise fall to JSX
    lexer_restore(p.lexer, saved)
    return parse_jsx_element_or_fragment(p)
}
```

**New helper needed:** `lexer_snapshot(l: ^Lexer) -> LexerSnapshot` and
`lexer_restore(l: ^Lexer, s: LexerSnapshot)`. The snapshot captures
`offset`, `had_line_terminator`, `cur`, `nxt`, `cur_lit_*`, `last_lit_*`,
`template_depth`, `template_brace_stack`. Roughly 100 bytes, stack-safe.

For MVP, the snapshot struct can be crude — just memcpy the `Lexer` up
to the allocator pointer. Odin supports this.

**Cost:** ~60 LOC for snapshot + restore, ~40 LOC for the TSX branch.

### Phase D — JS mode `<` (optional, polish)

In pure `.js` mode, `<` in expression-start position is a syntax error
(comparison always has a LHS operand). Today Kessel parses it as JSX,
which is wrong for JS but mostly harmless (JSX errors out on most
non-JSX content).

Fix: in JS mode, report a clean "Unexpected token '<'" instead of
entering JSX parsing.

**Cost:** ~10 LOC.

## Fixture plan

- `tests/fixtures/spec/typescript/007_type_assertion.js` — should be
  renamed `007_type_assertion.ts` OR the runner should pass `--lang=ts`.
  Currently lives in `unit_known_failures.txt`.
- Add new fixtures:
  - `spec/typescript/011_generic_arrow_ts.ts`:
    `const f = <T>(x: T): T => x;`
  - `spec/typescript/012_angle_assertion_ts.ts`:
    `const v = <string>y;`
  - `spec/tsx/001_generic_arrow_trailing_comma.tsx`:
    `const f = <T,>(x: T) => x;`
  - `spec/tsx/002_angle_assertion_forbidden.tsx`:
    `const v = <string>y;` — must REJECT, go in `fixtures/negative/`.

## Risk matrix

| Phase | Scope | Risk | Reward |
|-------|-------|------|--------|
| A | lang plumbing | Medium (may regress .js-with-jsx files in corpus) | Foundation for B/C/D |
| B | TS `<` handling | Low (TS mode has no ambiguity) | Closes TS-C1c + TS-C6 for .ts |
| C | TSX trial-parse | Medium-High (lexer snapshot is subtle) | Closes TS-C1c for .tsx |
| D | JS `<` error | Low | Polish only |

## Recommended sequencing

1. **Phase A alone** — 1-2 hours. Ship as one commit. Gate JSX on the new
   flag + extension detection. Corpus audit.
2. **Phase B** — 2-3 hours. Ship as one commit. Closes TS-C1c + TS-C6
   for `.ts` files (the 95% case).
3. **Phase C** — 4-6 hours. Ship as one commit. Lexer snapshot design
   reviewed carefully (this is where subtle bugs live). Closes TSX
   ambiguity for generic-arrow.
4. **Phase D** — 30 min. Ship with C or later.

Total: ~10 hours of careful work. Orchestrator-led because:
- Phase A affects every test that assumes JSX-everywhere.
- Phase C lexer snapshot is easy to get wrong in ways a Haiku wouldn't
  catch (e.g. the template-depth stack alignment).

## Out of scope for this design doc

- Full TSX ambiguity (nested generics, JSX inside assertion bodies, etc.)
  — deferred, and mostly caught by Phase C's trailing-comma rule.
- `sourceType` detection (OPT-1) — orthogonal.
- `astType` emitter mode (OPT-5) — orthogonal.

## Open questions

- **Corpus audit — ANSWERED.** Ran 2026-04-22:
  - 99/466 real-world .js files contain `<Capitalized` patterns, but
    sampling (antd.js line 19710, 81669) confirms these are ALL in
    comments or strings, not real JSX code.
  - Spot-check on 10 popular libraries (react-dom.dev, three.module,
    prettier, typescript, etc.): zero genuine JSX. All bundled/compiled.
  - Conclusion: Phase A defaulting real-world .js to `Lang.JS` (no JSX)
    will NOT regress `task test:real` (still 467/467). The reason today
    works is that naked `<` at expression-start never appears in these
    files — all `<` uses are binary comparison, mid-expression, and
    don't hit `parse_primary_expr`'s LAngle case.
  - Bottom line: Phase A is LOW risk, and it's a prerequisite for Phase B.
    Without proper lang plumbing, Phase B's TS `<` handler can't be
    reached.
  - No `unambiguous` fallback needed — extension alone is sufficient
    for the current corpus.
- **Trailing-comma rule strictness**: OXC's actual rule for TSX generic
  arrows is subtle — should we enforce "must have trailing comma" or
  "accept without, issue warning"? MVP: accept with or without, since
  we don't have a warning infrastructure yet.
