# Known bugs

Divergences between Kessel and OXC ESTree output discovered during the
deep verification pass. Fixed items are listed at the bottom with their
commit hashes; open items are tracked here.

## d3.js `execSync` SIGSEGV (pre-existing)

`kessel raw bench/real_world/d3.js` crashes with SIGSEGV when invoked
via Node's `child_process.execSync`, but succeeds when run from a shell.
Reproduces on the baseline handoff commit, so it is not a regression
from the current fix series.

**Repro**:
```
node -e 'require("child_process").execSync("./bin/kessel raw bench/real_world/d3.js --out /tmp/d.bin", {stdio:"ignore"})'
```

**Suspected area**: arena allocation / mmap under spawned processes with
different RLIMIT defaults, or an Odin runtime `os.flush(os.stdout)` path
that aborts when stdio is detached. Needs `lldb` attach to investigate.

**Workaround**: `verify_integration.js` users can exclude d3.js from the
sample set until this is root-caused.

## Pre-existing parse failures in 34/467 real-world files

`task test:real` reports 34 failures (vue.global.js 22 errors,
typescript.js 9 errors, ~30 more across batch2/batch3). These are
present on the baseline handoff commit — the HANDOFF.md claim of
"467/467 real-world JS files parse with 0 errors" was stale. Not
tracked individually here because they're a separate investigation
from the ESTree correctness pass.

---

## Fixed

- **Bug H** (577c237): three arrow-function builders stored a
  `^BlockStatement` in an `^Expression` field via
  `transmute(^Expression)block_stmt`. `rewrite_arrow_function` then
  silently corrupted the BlockStatement's `loc.span.*` by treating
  the first 8 bytes as a union pointer. Fix: new
  `ArrowFunctionBody :: union { ^Expression, ^BlockStatement }`, three
  parser sites switched to direct assignment, `rewrite_arrow_function`
  dispatches on the tag.
- **Bug E** (9935fa8): `lex_string` published raw source bytes as
  `StringLiteral.value`, so `"\x20\t"` produced the 4-char source
  string instead of the decoded space+tab. Fix: escape-decode in
  `lex_string_scalar` (ECMA-262 §12.9.4) into an arena-allocated
  dynamic buffer, publish via `last_lit_*`, dispatch in
  `advance_token`/`prime_token_cache`. Verified against
  `tests/fixtures/edge/string_escapes.js` (15/15) and jquery.js.

- **Bug A** (5d1f49…b80382e): `lex_hex` / `lex_binary` / `lex_octal`
  tokenized the literal but never computed its value. `0xff` parsed as
  `value: 0` instead of `255`. Fix: decode digits and populate
  `last_lit_value` like `lex_number` does for decimals.
- **Bug B** (432c102): `new X(args)` produced NewExpression with a
  CallExpression callee instead of X itself. Fix: `parse_member_expr`
  via `parse_lhs_tail(allow_call=false)` for the new-callee position.
- **Bug C** (N/A — verifier spec error): reported as kessel-side
  `computed=true` on plain object properties, actually caused by wrong
  stride in the verifier (40 vs real 48 because `PropertyKind` enum is
  8 bytes in Odin).
- **Bug D** (857647a): `ArrowFunctionExpression.expression` always
  `true`. Fix: capture `is_block_body := is_token(.LBrace)` BEFORE
  parsing the body, then use `!is_block_body`.
- **Bug F** (857647a): `parse_export_default` transmute UB. Fix: allocate
  ExportDefaultDef and box via union assignment; extract function-form
  expression via `stmt^.(^ExpressionStatement).expression`.
- **Bug G** (77531f4): `parse_try_statement` / `parse_catch_clause`
  transmute UB on block/finalizer/catch-body — silently truncated the
  block to empty. Fix: extract `^BlockStatement` via union cast.
- **Function expression UB** (432c102): `parse_function_expression` did
  `transmute(^FunctionDeclaration)stmt`, and `parse_function_declaration`
  boxed via `(^Expression)(expr)` pointer cast instead of
  `expression_from(p, expr)`. Fixed together.

## Related tooling fixes (in 9935fa8)

- `tests/verify_raw_deep.js` was silently unusable: literal `[ ... ]` /
  `{ ... }` placeholders in the JSON emitter broke `JSON.parse`, and
  literal type names weren't normalized against OXC's `"Literal"`.
  Both fixed; verifier now runs green on fixtures.
- `tests/verify_string_escapes.js` added: walks Kessel's truncated JSON
  and OXC's full ESTree in parallel, pairs strings by `raw`, compares
  `value` after escape decoding. Use for string-escape regressions.
- `tests/fixtures/edge/string_escapes.js` added: 15 escape patterns
  covering every shape in ECMA-262 §12.9.4.
