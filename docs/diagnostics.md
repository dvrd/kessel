# Diagnostics — Design Document

> Reference for kessel's diagnostic system: the stable `K####` error
> codes, the `error` / `warning` severity channel, the three on-the-wire
> surfaces (pretty, JSON, binary), the CLI controls that pick between
> them, and the call-site API contributors use when adding a new error.

## What a diagnostic is

Every problem kessel reports — bad token, missing semicolon, await
outside an async function, duplicate `static` modifier — flows through
a single record:

```odin
ParseError :: struct {
    start:    u32,         // byte offset (UTF-8) of the span start
    end:      u32,         // byte offset of the span end (exclusive)
    message:  string,      // final human wording; quotes source where useful
    code:     ErrorCode,   // .None for legacy / un-migrated sites, otherwise K####
    severity: Severity,    // .Error today; .Warning reserved for future lints
}
```

`ParseError` lives in `src/parser.odin`. The companion enums
(`ErrorCode`, `Severity`), the lookup table (`error_info`), and the
source-aware token formatters (`format_actual_token`,
`format_expected_token`) all live in `src/diagnostic.odin`. The
rustc-style pretty renderer is `src/diagnostic_render.odin`.

A finished parse owns one flat slice of `ParseError` on the parser's
arena. Whatever surface the caller picked (pretty, JSON, binary) reads
that slice and shapes it for the wire. Nothing else is computed twice.

## Code namespace

Every error site that has been migrated carries a `code` field whose
numeric value is the stable identifier. The string form is `K####`
with a four-digit zero-padded body (`error_code_string`).

| Range  | Pass         | Examples                                                                   |
|--------|--------------|-----------------------------------------------------------------------------|
| K1xxx  | Lexer        | `K1010` invalid numeric literal, `K1012` invalid regex, `K1013` unterminated string |
| K2xxx  | Parser       | `K2002` expected token, `K2010` expected `;`, `K2040` unexpected token      |
| K3xxx  | ECMA-262     | `K3011` `await` outside async context, `K3036` duplicate object key, `K3050` strict-mode reserved word |
| K4xxx  | TypeScript   | `K4030` modifier order, `K4050` ambient-context restriction, `K4080` duplicate implementation |

Codes are **stable across releases.** Once a code ships, its numeric
body never changes meaning. Tooling can safely match on `K3036` for
suppression, grouping, or editor squigglies forever. New codes get a
new number; renaming an enum variant (Odin identifier) is allowed only
if the numeric body stays the same.

`code = .None` (zero) is the legacy sentinel for un-migrated sites.
The vast majority of sites have been migrated; a handful of remaining
ones still report `.None`. Consumers must treat absence of `code` as
"no stable code", **not** as a specific code.

### Full catalogue (as of the Phase 5 rebuild)

The authoritative list is the `ErrorCode` enum in `src/diagnostic.odin`.
The canonical default message, optional hint, and optional TypeScript
error-code mapping live in the `error_info` table in the same file.

There are 80 codes. The exact name and message of each is documented
in source — see `error_info` for the table and each call site for the
final wording. Tooling that wants a machine-readable list should
generate it from the enum directly:

```bash
grep -oE 'K[1-4][0-9]{3}_[A-Za-z]+' src/diagnostic.odin | sort -u
```

### TypeScript code mapping

When kessel's code corresponds 1:1 to a `tsc` error, the
`error_info(code).ts_code` field carries the TS code as a string
(`"TS1005"`, `"TS1109"`, `"TS1308"`, ...). The pretty renderer prints
this as a `note: see TS####` line so editors that already know the TS
error number have a hook into existing documentation. Codes with no
TS analogue leave `ts_code` empty.

## Severity

```odin
Severity :: enum u8 {
    Error   = 0,   // zero value
    Warning = 1,
}
```

The substrate supports two channels but every diagnostic kessel emits
today is `.Error`. The `Warning` slot is reserved for future opt-in
lints — candidates the design contemplates:

  - `with` statement outside strict mode
  - empty block
  - unreachable code after `return` / `throw`
  - sketchy regex patterns (large alternations, catastrophic backtracking shapes)

The wire-format on every surface already carries severity, so warnings
will land without a format break.

## Surfaces

A finished parse produces one slice of `ParseError`s. Three callers
read that slice and shape it for the wire.

### 1. Pretty (rustc-style) — the default

Default output of `kessel parse FILE`. Renderer in
`src/diagnostic_render.odin`; writes to stderr. Block per diagnostic:

```text
error[K3011]: 'await' is only allowed within async functions and at the top levels of modules
  --> demo.mjs:1:16
   |
 1 | function f() { await x; }
   |                ^^^^^
  = note: see TS1308
```

Per diagnostic the renderer prints:

  - header (`error[K####]: message` — `error` is bold-red, `warning` is bold-yellow)
  - location (`  --> path:line:col`)
  - source snippet with caret underline (single-line or multi-line with `...` elision)
  - optional `  = hint: ...` from `error_info(code).hint`
  - optional `  = note: see TS####` from `error_info(code).ts_code`

Color is gated by `cfg.color` (see CLI controls below). The renderer
itself takes a plain `use_color: bool` — env / fd peeking is done at
the CLI layer so the renderer stays a pure function.

### 2. JSON (`--json`)

`kessel parse FILE --json` prints the ESTree AST as JSON to stdout
with the trailing `errors[]` array. Kessel format (the default):

```json
{
  "code": "K3011",
  "severity": "error",
  "message": "'await' is only allowed within async functions and at the top levels of modules",
  "line": 1,
  "column": 16,
  "offset": 15
}
```

`code` and `severity` are emitted **only when `code != .None`** so
pre-Phase-5 consumers that read only `{ message, line, column, offset }`
stay byte-compatible until they opt in.

The legacy OXC TS-ESTree shape `--errors=oxc` is also supported and
omits the code / severity / hint extensions; it exists for
parser-vs-parser benchmark parity and is not the recommended consumer
surface.

### 3. Binary (FFI / npm)

The native shared library `libkessel.{dylib,so,dll}` returns a
compact binary AST buffer over koffi. The format includes a small
`errors[]` section after the node stream. Layout depends on the
header `version` field:

  - v3 (legacy): `u32 start, u32 end, u32 msg_len, msg_len bytes UTF-8` — 12 bytes fixed
  - **v4 (current):** `u32 start, u32 end, u16 code, u8 severity, u8 _pad, u32 msg_len, msg_len bytes UTF-8` — 16 bytes fixed

`severity` is `0` for error, `1` for warning. `code = 0` means
"no stable code" (legacy sentinel) and the npm reader omits the
`code` / `severity` fields entirely so the JS shape matches the
JSON path.

The npm reader `npm/kessel/binary-reader.js` accepts both v3 and v4
for back-compat during the v4 rollout. Once every platform sub-package
ships a v4-capable native binary, the v3 fallback can drop.

### Semantic pass (`--show-semantic-errors`)

The default `parse` command runs only passes 1 + 2 (lex + parse).
The semantic checker (`src/checker.odin`, pass 3) is opt-in via
`--show-semantic-errors`. When set, the checker walks the finished
AST and merges its diagnostics into the same `p.errors` slice the
parser builds, so every surface picks them up automatically.

Reason for the opt-in: parser-only output matches OXC's `parseSync`,
which is what benchmark code compares against. Editors and users who
want the full ECMA-262 early-error set pass the flag.

## CLI controls

| Flag                          | Effect                                                                 |
|-------------------------------|------------------------------------------------------------------------|
| _(none)_                      | Pretty diagnostics on stderr, exit 1 if any errors.                    |
| `--json`                      | AST as JSON on stdout. Errors appear in the AST's `errors[]` array. Pretty diagnostics still go to stderr. |
| `--stats`                     | Append the per-parse arena + error-count block on stderr.              |
| `--show-semantic-errors`      | Also run pass 3 (semantic checker).                                    |
| `--color=true` / `--color=false` | Force ANSI color on or off in pretty output.                        |
| `--pretty`                    | Backwards-compat alias — pretty is now the default; this is a no-op.   |
| `--errors=oxc`                | Switch the JSON `errors[]` shape to the OXC TS-ESTree layout.          |

### Color resolution

Three inputs, highest priority wins:

  1. `--color=true` / `--color=false` — CLI flag (strictest)
  2. `KESSEL_COLOR=1` / `KESSEL_COLOR=0` — env var
  3. Default: `true`

Only `true` / `false` (flag) and `1` / `0` (env) are accepted. Any
other value is a startup error — silent fallback hides typos. The
legacy short forms `--color` and `--no-color` are explicitly rejected
so they don't get swallowed as positional filenames. There is no
`auto` mode — kessel's contract is "color unless told otherwise".

### Exit codes

  - `0` — parse succeeded, no errors
  - `1` — one or more errors reported (`--json` keeps stdout valid; the AST still parses)
  - `2` — invalid CLI usage (bad flag value, missing arg)

## Adding a new code

Recipe for contributors. The fixture-fix-snap-diff workflow in
`AGENTS.md` is the per-commit cadence; this is what changes inside
the fix.

1. **Pick the right range.** Lex-level → `K1xxx`. Parser-syntax →
   `K2xxx`. ECMA-262 early errors → `K3xxx`. TypeScript-only →
   `K4xxx`. Within the range, pick the next free number; keep
   related codes adjacent if it doesn't conflict.

2. **Add the enum variant** in `src/diagnostic.odin` under the right
   range comment. Name format: `K<num>_<PascalCaseShortName>` where
   the short name is verb-or-noun-phrase (e.g.
   `K3036_ObjectLiteralDuplicate`, `K4030_ModifierOrder`).

3. **Add the `error_info` entry** in the same file. Fill:
   - `default_message` — canonical wording for any future caller
     that wants a generic message. Call sites that quote source text
     pass a richer string at the call site and the table message is
     not used.
   - `hint` — optional second line in pretty output. Keep it
     actionable ("remove the stray comma, or fill in the missing
     type"); empty when there's no helpful hint.
   - `ts_code` — set to the matching TypeScript code (`"TS####"`) if
     one exists, otherwise `""`.
   - `severity` — `.Error` unless you're shipping a real warning.

4. **Wire the call site.** Use one of:

   ```odin
   report_error_coded(p, .K####_Name, "message")
   report_error_coded_span(p, .K####_Name, start, end, "message")
   ck_report_coded(c, loc_offset, .K####_Name, "message")
   ```

   Avoid the bare `report_error` / `ck_report` legacy helpers — those
   are the un-coded path. New sites always carry a code.

5. **Build the message at the call site** with `format_actual_token` /
   `format_expected_token` when quoting source. Helpers produce
   strings like `identifier 'foo'`, `numeric literal '0x1f'`, `')'`,
   `'const'`.

6. **Add a fixture** that triggers the new code under
   `tests/coverage/misc/pass/` (must-parse) or
   `tests/coverage/misc/fail/` (must-reject), per `AGENTS.md`. Then
   `task test:coverage:update` regenerates the misc snap; review the
   diff.

7. **Run `task test`.** Primary gate is non-negotiable.

## Wording style

Style notes carried over from the Phase 5 audit. Every new
diagnostic follows them.

  - **Quote source tokens with single quotes.** `'await'`, not
    `` `await` `` or `"await"`. Two reasons: visual consistency with
    rustc / tsc / biome, and the JSON output can pass the message
    through without re-quoting.
  - **No trailing period.** Messages are sentence fragments that get
    framed by the renderer; the period adds noise without information.
  - **Sentence-case start.** `'await' is only allowed ...`, not
    `'AWAIT' is only allowed ...` and not `'await' Is only allowed ...`.
  - **Lead with the offending construct, not "Cannot".** Prefer
    `'X' cannot be used as ...` over `Cannot use 'X' ...`. The
    construct is what the reader is looking at; lead with it.
  - **Be specific about the source position.** `Expected '}'`, not
    `Expected closing brace`. The single-quoted glyph is what they'll
    type to fix it.
  - **Hints answer "how do I fix this?"** not "what does the rule
    say?". The message says what's wrong; the hint says what to do.

## Performance notes

The diagnostic substrate is on the cold path — it fires only on the
error path. But the helpers are still designed so they don't trash
the hot path either:

  - `error_info` is a `#partial switch` over a `u16` enum. Compile-time
    dispatch, branchless lookup, no map.
  - `ErrorInfo` strings are compile-time literals — no allocation.
  - `error_code_string` formats `"K%04d"` into the parse-job's temp
    allocator. Allocations live for the duration of the parse job
    and die with the arena.
  - `format_actual_token` / `format_expected_token` allocate the
    same way — message strings are temp-allocated and die with the
    arena. No global state.
  - `report_error_coded` is two field reads, a struct construction,
    and a `bump_append`. No branching on severity.

The hot path (parser + lexer success case) never touches the
diagnostic substrate.

## File map

| File                          | Role                                                            |
|-------------------------------|-----------------------------------------------------------------|
| `src/diagnostic.odin`         | `ErrorCode` enum, `Severity`, `error_info` table, `error_code_string`, `severity_string`, `format_actual_token`, `format_expected_token`. |
| `src/diagnostic_render.odin`  | `render_pretty_diagnostics` — the rustc-style block renderer.   |
| `src/parser.odin`             | `ParseError` struct, `report_error*` helpers, all parser call sites. |
| `src/checker.odin`            | `ck_report*` helpers and the semantic-checker call sites.       |
| `src/lexer.odin`              | `LexerError` struct; promoted to `ParseError` at the start of every parse. |
| `src/regex.odin`              | `RegexDiagnostic` struct; promoted to `LexerError` after regex validation, then to `ParseError` like the rest. |
| `src/emitter.odin`            | `emit_errors` — kessel and oxc JSON shapes.                     |
| `src/binary_emitter.odin`     | `bin_emit_errors` — binary format v4 error section.             |
| `src/cli_config.odin`         | `CliConfig`, `cli_try_parse_flag`, `KESSEL_COLOR` resolution.   |
| `npm/kessel/binary-reader.js` | JS-side decoder. Handles v3 and v4.                             |
| `npm/kessel/types/index.d.ts` | TypeScript bindings — `ParseError`, `Severity`, `ErrorCode`.    |

## See also

  - `docs/binary-ast-design.md` — the binary AST wire format kessel
    speaks over FFI. The error section described above is appended
    to that format.
  - `AGENTS.md` — project guide, conformance methodology, development
    workflow.
