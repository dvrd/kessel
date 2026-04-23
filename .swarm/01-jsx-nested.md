TASK: Fix the JSX nested-attribute crash so that `<Foo bar={<Baz/>} />` parses cleanly instead of exiting 133.

## Context
Kessel is an Odin-written JS/TS/JSX parser. Fixture `tests/fixtures/spec/jsx/005_nested_element.js` (content: `const a = <Foo bar={<Baz x={1} />} />; const b = <Outer><Middle><Inner /></Middle></Outer>;`) currently crashes the parser with exit 133 (assertion failure on span invariants). The second line works — the bug is specific to a JSX element appearing as an attribute value inside `{ … }`.

The file `tests/baselines/unit_known_failures.txt` lists `spec/jsx/005_nested_element` as expected-to-fail; the fix must remove that entry so the gate enforces it.

Look at `src/parser.odin` around **L5186-5224** (`parse_jsx_opening_element`). The attribute-value path on `.LBrace` is:
```odin
} else if is_token(p, .LBrace) {
    eat(p); expr := parse_assignment_expression(p); expect_token(p, .RBrace)
    container := new_node(p, JSXExpressionContainer)
    container.loc = cur_loc(p); container.expression = expr
    attr_value = expression_from(p, container)
}
```

`parse_assignment_expression` → `parse_primary_expr` (src/parser.odin L3571) which DOES dispatch `.LAngle → parse_jsx_element_or_fragment` (L3831-3832). So the JSX inner element SHOULD parse. The crash almost certainly comes from `container.loc = cur_loc(p)` — at that point `cur_loc(p)` is the position AFTER the `}`, so `container.loc.span.start > container.loc.span.end` when we later set end, OR the span invariant `start <= end` fires in `emit_span_fields` (src/main.odin L1374). Likely root cause: `container.loc` must be captured BEFORE `eat(p)` of `.LBrace`, and `.span.end` must be set AFTER `expect_token(p, .RBrace)` via `prev_end_offset(p)`, the same idiom used 30+ times elsewhere in the file.

## Exact scope
Allowed edits:
- `src/parser.odin` — only `parse_jsx_opening_element` and, if strictly necessary for symmetry, the `.LBrace` branch in `parse_jsx_children` (L5239-5266 area).
- `tests/baselines/unit_known_failures.txt` — remove the line `spec/jsx/005_nested_element`.

Forbidden:
- Any other file in `src/`.
- Any change to `tests/fixtures/`, `tests/verifiers/`, `tests/expected/`, `tests/baselines/*.json`.
- Any dep change, any task in `Taskfile.yml`.

## Requirements
1. In `parse_jsx_opening_element`, when the attribute value is `{ expr }`, capture the `{` location BEFORE eating the token and set `container.loc.span.end` from `prev_end_offset(p)` AFTER the matching `}`. Apply the same pattern in `parse_jsx_children`'s `.LBrace` branch if it has the same bug.
2. The outer attribute `.loc` line `attr.loc = cur_loc(p)` must NOT be set after we've already consumed the attribute value — it must be the opening identifier location with span.end = prev_end_offset(p). Fix that too if the fixture still crashes after (1).
3. After the fix, `<Foo bar={<Baz/>} />` must parse, emit a JSXElement with a JSXAttribute whose value is a JSXExpressionContainer whose expression is a JSXElement for `<Baz/>`.

## Verification
Run these in order. Each must match the expected outcome.

1. `task build` — exits 0.
2. `echo 'const a = <Foo bar={<Baz/>} />;' | ./bin/kessel --stdin 2>&1 | head -5` — must print the first lines of a valid JSON AST (starts with `{`), exit 0, NO assertion failure, NO exit 133.
3. `./bin/kessel tests/fixtures/spec/jsx/005_nested_element.js >/dev/null 2>&1; echo $?` — must print `0`.
4. `task test:unit` — 211/211 pass (or N/N where N is current total), no regression. With the line removed from `unit_known_failures.txt`, the fixture is now enforced positively.
5. `task test:real` — must still be 467/467 (no regression).
6. `task test:regression` — 11/11 pass.
7. `task test` full chain — must not stall, must end green.

## Hard constraints
- Do NOT modify any fixture.
- Do NOT change any `.json` baseline. If `spec_fixtures_baseline.json` flags a new diff for this fixture, STOP and report it — the orchestrator will decide whether to re-baseline.
- Do NOT touch `src/ast.odin`, `src/lexer.odin`, `src/main.odin`, `src/raw_transfer.odin`, `src/simd.odin`, `src/token.odin`.
- Do NOT create git commits.
- Use the `prev_end_offset(p)` idiom already established in the file. Do NOT invent a new offset helper.

## Final report
- File(s) changed with a one-line summary of the diff per file.
- Full stdout of verification steps 2, 3, 4.
- Confirmation that `task test:real` stayed at 467/467.
- If step 2 still crashes, include the exact assertion message and where you think it originates.
