TASK: Add optional `loc: { start: { line, column }, end: { line, column } }` emission on every AST node, controlled by a `--loc` CLI flag. Off by default for backward compat.

## Context
OXC emits per-node locations:
```json
{ "type": "Identifier", "start": 0, "end": 3, "name": "foo",
  "loc": { "start": { "line": 1, "column": 0 }, "end": { "line": 1, "column": 3 } } }
```
Kessel emits only `start` and `end` byte offsets today. Infrastructure is ready: `offset_to_line_col` (src/lexer.odin L115-128) converts offset → line/col, and `build_line_table` populates the table. Already used for error messages only (main.odin L664).

The ONE helper that emits `start`/`end` on every node is `emit_span_fields` (src/main.odin L1374). Every AST node funnels through this. Adding the `loc` block in this one helper gives 100% coverage for free.

CLI flag parsing lives at the top of `main :: proc()` in `src/main.odin` — follow the pattern of `--errors=` / `--stdin` / `--filename`.

## Exact scope
Allowed edits:
- `src/main.odin` — only:
  1. CLI argument parser: add `--loc` boolean flag, store in a `config_loc: bool` or `emit_loc_enabled: bool` global/package variable (match existing flag patterns).
  2. `emit_span_fields` (L1374): when the flag is on, append `,\n<indent>"loc": { "start": { "line": N, "column": M }, "end": { "line": P, "column": Q } }` after the `end` field.
  3. `emit_span_leading` (L1389) — same logic, same helper, parallel block.
  4. Before `print_program_ast` is called, ensure `build_line_table(p.lexer)` runs once (look for an existing `build_line_table` call in the error branch at L651; hoist it so it runs unconditionally when `--loc` is on).

Forbidden:
- Any other src file.
- Any change to default output. Without `--loc`, the JSON must be byte-identical to today.
- Any fixture, verifier, baseline change.

## Requirements
1. Default: `./bin/kessel x.js` produces IDENTICAL output to pre-change. Byte diff must be empty.
2. `--loc`: every node that today has `"start": N, "end": M` ALSO has `"loc": { "start": { "line": L1, "column": C1 }, "end": { "line": L2, "column": C2 } }`. Lines are 1-indexed, columns are 0-indexed (matching ESTree / OXC convention; verify against the existing error-emit code at L664-666 — it emits `line`/`column` as 1-indexed for humans, but ESTree `loc` uses 0-indexed column; OXC specifically does 0-indexed column).
3. Columns are UTF-16 columns, not byte columns, to match OXC. The existing `to_utf16` conversion in main.odin must be used for column numbers too. Look how `to_utf16` is called for `start`/`end` in `emit_span_fields`; emit the same conversion before computing the column offset within a line.
4. Performance: the flag is off by default, so the cost must be exactly zero when off. With `--loc` on, the line table is O(source_size) once and each node does an O(log lines) binary search. Document this in a one-line comment above `emit_span_fields`.

## Verification
Run these in order:

1. `task build` — exits 0.
2. Byte-identical default:
   ```bash
   F=tests/fixtures/basic/$(ls tests/fixtures/basic/ | head -1)
   git stash; task build; ./bin/kessel "$F" >/tmp/before.json 2>/dev/null
   git stash pop; task build; ./bin/kessel "$F" >/tmp/after.json 2>/dev/null
   diff /tmp/before.json /tmp/after.json
   ```
   — must produce NO output (identical). (If git-stashing is impractical, just verify that `task test:nodes` still passes without the flag — same guarantee.)
3. `echo 'var x = 1;' | ./bin/kessel --stdin --loc 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); p=d['program']['body'][0]; print(p.get('loc'))"` — must print a dict with `start` and `end`, each a dict with `line` and `column`.
4. `echo 'var x = 1;' | ./bin/kessel --stdin --loc 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); ids=[x for x in d['program']['body'][0]['declarations']][0]['id']; print(ids['loc'])"` — must show the Identifier loc with line 1.
5. `task test:unit` — full pass.
6. `task test:regression` — full pass.
7. `task test:real` — must stay at 467/467.
8. `task test:nodes` — must not drift (baseline-locked).

## Hard constraints
- Do NOT change `emit_span_fields`/`emit_span_leading` signatures — the flag must be read from a package-level variable.
- Do NOT compute line/col on every node when `--loc` is off; guard with `if emit_loc_enabled`.
- Do NOT regress hot-path performance for the default mode. The hot-path assertion in `emit_span_fields` (`assert(loc.span.start <= loc.span.end)`) must stay.
- Do NOT create git commits.
- Use `out_u32(to_utf16(...))` for numeric emission; use `print_indent`/`out_s` for structure. Match existing style.

## Final report
- Diff summary for `emit_span_fields` and `emit_span_leading`.
- Output of step 2 (must be empty).
- Output of step 3.
- Confirmation `task test:nodes` stayed green.
