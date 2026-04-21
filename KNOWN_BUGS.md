# Known bugs

Divergences between Kessel and OXC ESTree output discovered during the
deep verification pass. Fixed items are listed at the bottom with their
commit hashes; open items are tracked here.

## Bug E — StringLiteral values are not escape-decoded

For `"[\\x20\\t]"` in source, OXC returns `value: "[\x20\t]"` (decoded:
space + tab). Kessel returns `value: "[\\x20\\t]"` (raw source bytes).

**Where**: `lex_string` / string cook path in `src/lexer.odin`. The
`.value` field is populated from raw source bytes instead of the cooked
(escape-decoded) form. `.raw` is correct.

**Impact**: jquery.js shows ~30 mismatches, all of this shape. Any tool
that consumes `value` gets wrong data.

## Bug H — Arrow function block body is transmuted into Expression union

`parse_arrow_function` (and the two async variants) parse the block
body as a `^Statement` and write it into the ArrowFunctionExpression's
`body: ^Expression` field via `body = transmute(^Expression)block_stmt`.
Same UB class as the FunctionExpression and TryStatement fixes, but not
yet visible because the verifier intentionally skips
`ArrowFunctionExpression.body` recursion.

**Where**: `src/parser.odin` — three sites: `parse_arrow_function`,
`parse_async_arrow_function`, `parse_async_arrow_with_parens`.

**Fix sketch**: ESTree wraps arrow-block bodies as BlockStatement. Kessel's
`Expression` union has no BlockStatement variant. Options:
  a. Add a BlockStatement variant to the Expression union.
  b. Change arrow body type to `union{^Expression, ^BlockStatement}`.
  c. Keep the transmute but tag it explicitly and teach the rewrite
     and verifier to recognize the block-body case.

Requires design work.

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
