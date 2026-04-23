TASK: Support ambient module bodies like `module "x" { const y: number; }` by treating statements inside a string-named `module` / `namespace` declaration as if they had an implicit `declare` modifier. Currently this crashes / errors.

## Context
In TypeScript, `declare module "foo" { const y: number; }` is the canonical form. But TypeScript *also* accepts `module "foo" { const y: number; }` when inside a `.d.ts` or when the module name is a string literal — the `declare` is implicit.

Today Kessel's parser at `src/parser.odin` L6092-6149 (`parse_ts_module_declaration`) parses the body as normal statements. Inside the body, a line like `const y: number;` without an initializer is rejected by `parse_variable_declarator` because `const` requires an initializer in non-`declare` context. This causes a parse error on the fixture (or crash on related ambient syntax).

The fix is a context flag: when entering an ambient-module body (string-named `module`, OR any `declare`-prefixed module/namespace), set `p.in_ambient = true` for the duration of the body, and `parse_variable_declarator` / other sites that check for required initializers must bypass the requirement when `p.in_ambient`.

Look at `parse_ts_module_declaration` (L6092) and `parse_ts_module_tail` (L6152). Both have a `for … parse_statement_or_declaration …` loop over the body block. The flag must be set before the loop and restored after.

Find every "require initializer" check in `parse_variable_declarator` and also the "disallow function body" check for ambient function decls. Grep:
- `grep -n "initializer\|has_init\|Const.*requires\|const.*init" src/parser.odin`

## Exact scope
Allowed edits:
- `src/parser.odin` — only:
  - Add `in_ambient: bool` field to the `Parser` struct (near `has_module_syntax`, L202).
  - In `parse_ts_module_declaration` and `parse_ts_module_tail`: before parsing the body, set `prev_ambient := p.in_ambient; p.in_ambient = true` when (a) name is a `StringLiteral`, OR (b) the containing context is already ambient (caller's `p.in_ambient` was true — for nested namespaces). Restore `p.in_ambient = prev_ambient` after the body.
  - In `parse_variable_declarator`: skip the "const must have initializer" / "let must have initializer" / ambient-rejection checks when `p.in_ambient`.
  - In `parse_function_declaration` / `parse_class_declaration`: when `p.in_ambient`, accept a signature without a body (existing `declare` handling path — reuse it).

Forbidden:
- All other src files.
- Fixture/baseline changes.

## Requirements
1. `module "foo" { const y: number; }` parses cleanly — the body is a `TSModuleBlock` containing a `VariableDeclaration(kind="const", declarations=[{id: "y", type_ann: number, init: null}])`.
2. `module "foo" { function f(x: number): void; }` parses cleanly — body contains a function declaration with NO body (equivalent to `declare function`).
3. `declare namespace N { const x: number; }` — still works as before (already handled; don't break).
4. OUTSIDE an ambient module, `const x;` still produces a parse error (the fix is scoped, not global).

## Verification
Run these in order:

1. `task build` — exits 0.
2. ```bash
   echo 'module "foo" { const y: number; }' | ./bin/kessel --stdin 2>&1 | head -5
   ```
   — must start with `{` (valid JSON), NOT produce a "const requires initializer" error.
3. ```bash
   echo 'module "foo" { function f(x: number): void; }' | ./bin/kessel --stdin 2>&1 | grep -c '"type": "TSModuleDeclaration"'
   ```
   — must print `1` or more.
4. Negative check — scope containment:
   ```bash
   echo 'const x;' | ./bin/kessel --stdin 2>&1 | grep -c 'error\|Error'
   ```
   — must print `1` or more (NOT zero — we must NOT have accidentally disabled the check globally).
5. `task test:unit` — full pass.
6. `task test:real` — must stay at 467/467.
7. `task test:regression` — green.
8. `task test` full chain — green.

## Hard constraints
- Do NOT make `p.in_ambient` global. It must be a field on `Parser` (scoped to parse).
- Do NOT break non-ambient behavior. `const x;` outside must still error.
- Use the save/restore idiom `prev := p.in_ambient; p.in_ambient = true; defer p.in_ambient = prev` so nested scopes work correctly.
- Do NOT create git commits.

## Final report
- File diff summary.
- Full stdout of verification steps 2, 3, 4.
- Confirmation `task test:real` stayed at 467/467.
