TASK: Accept `\uXXXX` and `\u{H...H}` unicode escapes inside JS identifiers so that `const \u0061bc = 1;` and `const h\u{65}llo = 2;` parse and produce identifiers named `abc` and `hello` respectively.

## Context
Kessel's lexer (`src/lexer.odin`) handles `\uXXXX` / `\u{...}` inside STRING literals (L800-820 area) but NOT inside identifiers. Fixture `tests/fixtures/spec/unicode/002_escape_in_identifier.js`:
```js
const \u0061bc = 1;
const h\u{65}llo = 2;
```
currently crashes (exit 133). ECMA-262 §12.7 requires accepting these: the decoded codepoint must itself be a valid IdentifierStart (for the leading char) or IdentifierPart.

The dispatch in `next_token` (around L395 in `src/lexer.odin`) does:
```odin
if is_id_start_fast(c) { return lex_identifier(l, start, flags) }
```
but never considers `c == '\\'`. And `lex_identifier` (L450-465) is a fast loop over `CHAR_CLASS_TABLE`; it cannot see escapes mid-identifier.

The AST identifier node consumes a `string` name. The `LiteralValue`/`last_lit_value` mechanism (see Lexer struct L66-78) is already used for cooked string literals — repurpose the same slot for cooked identifiers. Parser sites that read identifier names slice `source[start:end]` today; for escape-containing identifiers they must prefer a cooked name from the lexer.

Fixture `tests/baselines/unit_known_failures.txt` currently lists `spec/unicode/002_escape_in_identifier` — remove the line as part of the fix.

## Exact scope
Allowed edits:
- `src/lexer.odin` — add an escape-aware identifier path. Specifically:
  - In `next_token`, add a `'\\'` fast-path BEFORE the `is_id_start_fast(c)` branch: peek `\u`, decode one codepoint, validate it's IdentifierStart, then enter a slow identifier loop that tolerates further `\u` escapes.
  - Add a slow-path `lex_identifier_escaped` proc OR extend `lex_identifier` with an "escape seen" fall-back that re-scans from `start`.
  - Publish the decoded name via `l.last_lit_value = LiteralValue(string(cooked_buf[:]))` and a new/existing `l.last_lit_type = .Identifier` so the parser can prefer it.
- `src/parser.odin` — only the identifier-construction sites that currently do `name = intern(p.interner, src[start:end])`. When the lexer reports `last_lit_type == .Identifier`, prefer the cooked string.
- `src/token.odin` — add `.Identifier` to `LiteralType` enum if missing.
- `tests/baselines/unit_known_failures.txt` — remove the line `spec/unicode/002_escape_in_identifier`.

Forbidden:
- Any change to `src/ast.odin`, `src/main.odin`, `src/raw_transfer.odin`, `src/simd.odin`.
- Any change to fixtures, verifiers, or `.json` baselines.
- Any dep change or Taskfile change.
- Do NOT try to decode escapes in keyword lookup: an identifier with `\u` MUST be treated as an Identifier, never as a keyword (ECMA-262 §12.7.2). Ensure `lookup_keyword_by_letter` is bypassed when any escape was seen.

## Requirements
1. `const \u0061bc = 1;` parses to a VariableDeclaration whose declarator's Identifier has `name == "abc"` and `start`/`end` span covering the full `\u0061bc` source text.
2. `const h\u{65}llo = 2;` parses to an Identifier with `name == "hello"`.
3. Reserved-word defeat: `let \u0069f = 3;` must parse (NOT trigger the `if` keyword) — `\u0069f` decodes to `if` but per spec an escaped identifier is always an Identifier, never a keyword. Add a smoke test for this.
4. Invalid escapes (`\u00GG`, unterminated `\u{…EOF`) must produce a lexer error and NOT crash.
5. Decoded codepoint whose value is NOT a valid IdentifierStart / IdentifierPart must error.

## Verification
Run these in order:

1. `task build` — exits 0.
2. `echo 'const \u0061bc = 1;' | ./bin/kessel --stdin 2>&1 | grep -c '"name": "abc"'` — must print `1`.
3. `echo 'const h\u{65}llo = 2;' | ./bin/kessel --stdin 2>&1 | grep -c '"name": "hello"'` — must print `1`.
4. `echo 'let \u0069f = 3;' | ./bin/kessel --stdin 2>&1 | head -30` — must parse (NOT produce a syntax error on `\u0069f`); the Identifier name is `"if"`.
5. `./bin/kessel tests/fixtures/spec/unicode/002_escape_in_identifier.js >/dev/null 2>&1; echo $?` — must print `0`.
6. `task test:unit` — full pass (with the known-failures line removed).
7. `task test:real` — must stay at 467/467.
8. `task test:regression` — must stay green.

## Hard constraints
- Do NOT modify any fixture.
- Do NOT modify any `.json` baseline. If a baseline flags a new diff, STOP and report.
- Hot path must not regress for the common case (no escape): the fast loop in `lex_identifier` must stay intact for ASCII identifiers. Only the escape-detection branch is new.
- `is_id_start_fast` / `is_id_cont_fast` operate on raw bytes, not codepoints. For the escape-decoded codepoints, you'll need a codepoint-level `is_id_start_codepoint` / `is_id_cont_codepoint`. A simplified version that accepts ASCII + any non-ASCII codepoint ≥ 0x80 is acceptable (matches what the raw-byte version does today).
- Do NOT create git commits.

## Final report
- File(s) changed with a one-line summary of the diff per file.
- Full stdout of verification steps 2, 3, 4, 5.
- `task test:real` count before and after.
- Any edge cases you deliberately left for follow-up (e.g. surrogate pairs across an identifier — probably not needed for the fixture but worth noting).
