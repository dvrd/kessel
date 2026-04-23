TASK: Emit parse errors in OXC's structured shape — `{ severity, message, labels: [{ span: { start, end } }] }` — behind a `--errors=oxc` CLI flag, leaving the current shape as the default for backward compatibility.

## Context
Today, `src/main.odin` L647-675 emits each parse error as:
```json
{ "message": "...", "line": N, "column": N, "offset": N }
```
OXC emits:
```json
{
  "severity": "error",
  "message": "Unexpected token",
  "labels": [ { "span": { "start": N, "end": N } } ]
}
```
We want OXC parity but without breaking existing consumers (our own verifiers, regression tests) that parse the current shape. So add a CLI flag `--errors=oxc|kessel` (default `kessel`). When `oxc`, emit the OXC-shaped object; when `kessel`, emit today's shape.

Parse error struct: look around L640-680 in `src/main.odin`. `err.loc.offset` is already UTF-8 byte offset; there is no `err.loc.end` today (errors are point-spans). For OXC parity, emit `span.start = err.loc.offset` and `span.end = err.loc.offset + 1` as a sensible default (most OXC error labels are 1-byte point spans too). If `err` carries an `end_offset` field, use it; if not, the +1 fallback is fine.

CLI argument parsing: `src/main.odin` already parses args. Look around the top of `main :: proc()` — find where flags like `--stdin` or `--filename` are handled. Add `--errors=<mode>` in the same style.

## Exact scope
Allowed edits:
- `src/main.odin` — the error emitter block around L640-680, and the CLI argument parsing block at the top of `main`.

Forbidden:
- All other files in `src/`.
- All fixtures, verifiers, and baselines. If the new default is backward-compatible, none of them should change.
- Taskfile.

## Requirements
1. Default behavior (no flag, or `--errors=kessel`): emit the EXACT current shape. A byte-level diff of `./bin/kessel <fixture>` before and after this task must be empty for every file in `tests/fixtures/real/` that produces errors. (Test one or two from `tests/fixtures/negative/` that do produce errors.)
2. `--errors=oxc`: emit for each error:
   ```
   {
     "severity": "error",
     "message": "...",
     "labels": [
       { "span": { "start": N, "end": N } }
     ]
   }
   ```
   — where `N` uses the same `to_utf16(...)` conversion the rest of the emitter uses for offsets (see the `emit_span_fields` proc at L1374 for the pattern).
3. `out_string(err.message)` (the JSON-string escaper) must be used for `message`, not raw concatenation. Preserve this for both modes.
4. If no errors exist, do NOT emit an `"errors": []` field in either mode (behavior stays identical).

## Verification
Run these in order:

1. `task build` — exits 0.
2. Pick a fixture that produces parse errors. Example: `./bin/kessel tests/fixtures/negative/$(ls tests/fixtures/negative/ | head -1) 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('errors',[])[0] if d.get('errors') else 'NONE')"` — must print a dict with `message`/`line`/`column`/`offset` keys (current shape, DEFAULT).
3. Same fixture with `--errors=oxc`: `./bin/kessel --errors=oxc tests/fixtures/negative/$(ls tests/fixtures/negative/ | head -1) 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); e=d.get('errors',[])[0] if d.get('errors') else None; print(list(e.keys()) if e else 'NONE')"` — must print `['severity', 'message', 'labels']`.
4. `task test:regression` — 11/11 pass (default shape unchanged, so no regression).
5. `task test:negative` — must still pass against the existing `negative_baseline.json` (no change to default output).
6. `task test:real` — must stay at 467/467.
7. `task test` full chain — green.

## Hard constraints
- Do NOT change the default error shape. If a baseline fails, the task has failed.
- Do NOT add a library dep.
- Do NOT create git commits.
- Use the existing `out_s`, `out_string`, `out_u32`, `out_printf`, `to_utf16`, `print_indent` helpers. Do NOT hand-roll JSON formatting.

## Final report
- Unified diff (or summary) of the CLI arg parsing block changed.
- Unified diff of the error emitter block.
- Full stdout of verification steps 2 and 3.
- Confirmation that `task test:regression` and `task test:negative` stayed green.
