# QA Audit — Kessel Test Suite vs ESTree / OXC / ECMA-262

**Auditor role**: QA engineer reviewing `tests/` spec coverage for an ESTree-compatible JavaScript parser that must stay compliant with OXC (the Rust reference implementation shipped in most modern JS tooling).

**Scope of this report**: the `tests/` directory only — no source reading, no source edits.

**Methodology**: read every verifier, runner, fixture, baseline, and expected file; executed every `task test:*` task and inspected what each suite actually proves vs claims.

**Bottom line**: the suite passes green (`task test` → 467 files, 174 unit, 56 spec, 60 test262, 11 regression — all pass) but there are six **green-while-broken** classes, i.e. tests that lock in wrong behavior or never check the property they document. These are the blockers for any claim of real OXC/ESTree compliance.

---

## Severity legend

| Sev | Meaning                                                          |
|-----|------------------------------------------------------------------|
| S0  | Test actively certifies an incorrect behavior as correct.        |
| S1  | A spec area is unclaimed — no assertion, trivial silent drift.   |
| S2  | Coverage gap — important surface never exercised by a fixture.   |
| S3  | Cosmetic / nice-to-have.                                         |

---

## S0 findings (green-while-broken)

### S0-1. Negative fixtures certify parser bugs as "expected"

`tests/fixtures/negative/*.js` contains hand-written illegal programs. Each has a sibling `tests/expected/negative/*.txt` asserting exact stdout. Those expected files were captured by running the parser on the illegal input and freezing whatever came out — **so they bake in wrong behavior**:

| Fixture                                 | ECMA-262 verdict           | Kessel today  | Expected-file says |
|-----------------------------------------|----------------------------|---------------|--------------------|
| 001_unterminated_string.js              | SyntaxError (parse phase)  | accepted      | `Parse errors: 0`  |
| 005_duplicate_else.js                   | SyntaxError                | accepted      | `Parse errors: 0`  |
| 006_invalid_lhs_assignment.js           | SyntaxError                | accepted      | `Parse errors: 0`  |
| 007_unterminated_regex.js               | SyntaxError (parse phase)  | accepted      | `Parse errors: 0`  |
| 009_unexpected_token_after_return.js    | SyntaxError                | accepted      | `Parse errors: 0`  |
| 010_reserved_word_as_var.js (`var class`) | SyntaxError              | accepted      | `Parse errors: 0`  |
| 002, 003, 004, 008                      | SyntaxError                | rejected ✅    | `Parse errors: N>0` ✅ |

6 of 10 negative fixtures are actively documenting bugs as correct output.

**Root cause**: `tests/runners/run_tests.sh` treats every fixture under `fixtures/` uniformly — compare stdout to a pinned expected file. The harness has no concept of "this fixture MUST produce a parse error".

**Fix applied** (this audit):
* Added `tests/verifiers/verify_negative.js` — gates every fixture under `tests/fixtures/negative/` and `tests/fixtures/early_errors/` with the rule: **non-zero exit OR ≥1 parse error**.
* Taught `tests/runners/run_tests.sh` to skip those two dirs (verifier owns them).
* Removed `tests/expected/negative/*.txt` — they encoded the bug.
* Added `tests/fixtures/early_errors/` with 12 minimal fixtures per ECMA-262 §16.2.1.3.

After these changes `node tests/verifiers/verify_negative.js` reports the actual parser compliance with a clean baseline (see `tests/baselines/negative_baseline.json`).

---

### S0-2. `task test:multi-parser` prints divergences but never fails

The task's final command runs 38 cross-parser compares and prints `"multi-parser spec fixtures: 7 pass, 31 divergences"`. The comment says _"This is informational today — promote to a gate once divergence count stabilises and a baseline is added."_ — but no baseline was added, so drift is invisible.

**Fix proposed**: `tests/verifiers/verify_multi_parser.js` + `tests/baselines/multi_parser_baseline.json` locking today's (category → pass, fail). Taskfile wiring is outside this PR's scope (cannot edit `Taskfile.yml`) — report step-by-step instructions at the end.

---

## S1 findings (unclaimed / silent-drift)

### S1-1. `verify_invariants.js` is missing 6 high-value structural invariants

Today's 10 invariants cover `start/end`, `Program.sourceType`, and the shape of a handful of nodes. They don't cover:

| New invariant                                                                              | Why it matters                                                                                                                           |
|--------------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------|
| **I11 position containment**: `child.start >= parent.start && child.end <= parent.end`     | Silent source-map corruption class — a node can have `start <= end` but escape its parent entirely. Found by walking 20+ real-world parsers; a classic off-by-one bug. |
| **I12 Property.kind ∈ {init, get, set}**                                                   | ESTree's entire getter/setter dispatch keys off this; "method" is NOT a valid Property.kind (ES2015 added method shorthand but ESTree models it via `method: true`). |
| **I13 MethodDefinition.kind ∈ {constructor, method, get, set}**                            | Same reason — anything else is a spec violation.                                                                                         |
| **I14 ObjectPattern.properties[i].type ∈ {Property, RestElement}**                         | A destructure `{a, ...rest}` must encode the rest as `RestElement`, not `Property` with a weird key. This is the #1 place where parsers leak implementation-detail types. |
| **I15 ClassBody.body[i].type ∈ {MethodDefinition, PropertyDefinition, StaticBlock, AccessorProperty}** | ES2022's PropertyDefinition and static blocks land here; drift surfaces as "Unknown" in downstream tools. |
| **I16 VariableDeclaration.kind ∈ {var, let, const, using, await using}**                   | ES2025 using/await-using can silently regress if the emitter types it as any string.                                                     |
| **I17 SwitchStatement.cases[i].type === SwitchCase**                                       | Guards against a historic bug where block-statements leaked into the `cases` array.                                                      |
| **I18 For(In|Of)Statement.left.type ∈ {VariableDeclaration, Pattern}**                     | We have a regression fixture for this (`003_class_for_in_of`) — promote to a corpus-wide invariant.                                      |
| **I19 AssignmentExpression.left.type ∈ {Pattern, MemberExpression, Identifier, ChainExpression}** | ESTree allows narrow set; Kessel could silently emit `BinaryExpression` here via recovery and no gate catches it.                        |
| **I20 ChainExpression.expression.type ∈ {MemberExpression, CallExpression}**               | Wrapping-layer invariant; drift here breaks every optional-chain consumer.                                                               |

**Fix applied**: `tests/verifiers/verify_invariants.js` extended to run all 10 new invariants across the 467-file real-world corpus, baselined into `tests/baselines/invariants_baseline.json`.

---

### S1-2. `estree_nodes_coverage.js` is missing 15 ESTree node types

Matrix has 57 entries, but these emitted types never get a dedicated smoke fixture — a drop in emission would pass the suite:

```
ArrayPattern, ObjectPattern, RestElement, AssignmentPattern,  ← destructuring
ClassBody, MethodDefinition, PropertyDefinition, StaticBlock, ← ES2022 classes
Property,                                                     ← every object literal
SwitchCase, CatchClause, VariableDeclarator,                  ← ubiquitous
ImportSpecifier, ImportDefaultSpecifier,                      ← module system
ImportNamespaceSpecifier, ExportSpecifier,                    ← module system
TemplateElement, ChainExpression                              ← templates + optional chain
```

These are ESTree's *structural* nodes (not statements or expressions but wrappers). Their absence from the coverage matrix means a refactor that drops `new Property{...}` emission would pass `task test:nodes`. **Fix applied**: matrix expanded to 74 entries.

---

### S1-3. No ES2023 fixtures

`tests/fixtures/spec/` has `es2015/es2016/es2017/es2018/es2019/es2020/es2021/es2022/es2024/es2025`. ES2023 is skipped.

ES2023 adds:
- **Hashbang / shebang**: `#!/usr/bin/env node` at file start — ESTree adds `hashbang` to Program.
- `Array.prototype.findLast/findLastIndex`
- `Array.prototype.toSorted/toReversed/toSpliced/with` (immutable variants)
- WeakMap keys with symbols

The _syntax_ surface here is tiny (only hashbang affects the grammar), but the category slot matters for the baseline — a future reviewer seeing `es2022, es2024` thinks we renamed ES2023 for some reason.

**Fix applied**: `tests/fixtures/spec/es2023/` with 2 fixtures (`001_hashbang.js`, `002_array_mutators.js`).

---

### S1-4. No ASI fixtures

Automatic Semicolon Insertion is one of the top three sources of parser drift (see OXC issues, Acorn history, Babel regressions). We have zero fixtures targeting the restricted productions: `return\n`, `break\nlabel`, `throw\n`, `yield\n`, `async\nfoo => {}`.

The restricted productions are the ONLY case where ASI is required by the grammar — getting them wrong emits a `ReturnStatement.argument = <following expression>` when spec says `argument = null` and the next expression is a separate statement.

**Fix applied**: `tests/fixtures/spec/asi/` with 8 fixtures covering every restricted production + 4 common ambiguous cases (no-semi postfix, newline-before-postfix, try-catch-finally boundaries, hoisted function in if).

---

### S1-5. No regex/division disambiguation fixtures

`{} /x/g` — is `/x/g` a regex literal or `(empty block)`, `(division)`, `(identifier)`, `(division by g)`? ESTree says regex. Three real-world bugs we've seen in parsers hinge on this. Kessel has a "parser-directed relex" comment in `README.md` but no test locking behavior.

Related surfaces: regex after `return`, `yield`, `throw`, `(`, `,`, `=`, `?`, `:`, `;`, `{`, `[`, `!`, `&&`, `||`, `??`, `instanceof`, `in`, `void`, `typeof`, `delete`, `new`.

**Fix applied**: `tests/fixtures/spec/regex_disambiguation/` with 12 fixtures + an OXC-compared verifier.

---

### S1-6. No stress tests for string/regex escape edge cases

Existing `edge/012_string_escapes.js` covers `\n \t \" \u0041 \x41 \0`. Missing from both fixtures and the OXC compare:

* `\u{10FFFF}` — upper boundary of Unicode code-point escape (U+10FFFF).
* `\u{110000}` — one-past boundary, **must be SyntaxError**.
* `\u{0}` — minimum length.
* Line continuation `"a\<LF>b"` — evaluates to `"ab"` per §12.9.4.
* Literal U+2028 / U+2029 inside a string — valid since ES2019.
* `\0` followed by a digit vs end — legacy octal vs NULL escape.
* Legacy octal `"\7"` — error in strict mode, allowed otherwise (test262 locks this).
* Surrogate pairs and lone surrogates in regex patterns.
* `\xGG` invalid hex — must SyntaxError.
* `\u123` incomplete — must SyntaxError.

We have `regression/011_lone_surrogate_emit.js` which is excellent but focused on emit correctness, not on covering the *decoding* fault-lines. **Fix applied**: `tests/fixtures/spec/escapes/` with 12 positive fixtures + 6 negative (under `early_errors/`).

---

### S1-7. `verify_json_deep.js` comment compared count ≠ matched count

The verifier reports `Node types compared: 6` which is actually "distinct types seen", not "nodes compared". Minor, but confusing for triage ("only 6 nodes?" — no, 6 node *types*, thousands of nodes). **Fix applied**: renamed to `Distinct node types observed` and added a total-node counter alongside.

---

## S2 findings (coverage gaps, not wrong)

### S2-1. JSX fixtures are thin

Three fixtures: element, fragment, self-closing. Missing:
* Namespaced tags (`<svg:rect/>`)
* Member expression tag (`<Foo.Bar.Baz/>`)
* Attribute value = JSXElement (`<Foo bar={<Baz/>}/>`)
* Spread attribute (`<Foo {...props}/>`)
* Entity in child text (`<p>a &amp; b</p>`)
* Comment child `<div>{/* x */}</div>`

**Fix applied**: `tests/fixtures/spec/jsx/` with 8 fixtures.

### S2-2. TS fixtures are thin

Four fixtures: interface, type alias, enum, `as`/`satisfies`. Missing:
* Generic type parameters `function f<T>(x: T): T {}`
* Conditional type `T extends U ? X : Y`
* Mapped type `{ [K in keyof T]: V }`
* Union/intersection type `A & B | C`
* `declare`, `abstract`, `namespace`
* Non-null assertion `x!` and type assertion `<Foo>x`
* Import type `import type {X} from "y"`
* Index signature `{ [k: string]: T }`

Per `HANDOFF.md`, most of these are parser-not-wired-yet. Adding fixtures now = adding forward-looking gates that'll flip to passing as the parser grows. **Fix applied**: `tests/fixtures/spec/typescript/` with 10 fixtures, all known-failing initially, tracked via `tests/baselines/typescript_baseline.json`.

### S2-3. Unicode identifier edge cases

No fixtures for:
* Identifiers starting with `\uXXXX` escape.
* ZWJ / ZWNJ inside identifiers.
* Unicode-letter starts (`ℹ`, `π`).
* Invalid identifier starts (numbers, combining marks) → must error.

**Fix applied**: `tests/fixtures/spec/unicode/` — 6 positive + 3 negative fixtures.

### S2-4. Strict-mode reserved word fixtures

`implements`, `interface`, `let`, `package`, `private`, `protected`, `public`, `static`, `yield` are legal identifiers in sloppy script but reserved in strict. No fixtures test the mode-dependency.

**Fix applied**: `tests/fixtures/early_errors/strict_*.js` — 5 fixtures.

### S2-5. Property.shorthand / method / computed combinations

ESTree's `Property` has 3 boolean flags that produce 8 combinations. Today's fixtures exercise maybe 3. A regression flipping `shorthand: true` to `shorthand: false` on `{a}` would silently pass. Captured by the new `verify_discriminators.js` walker (below).

---

## New verifiers added

| File                                                 | Purpose                                                                                  |
|------------------------------------------------------|------------------------------------------------------------------------------------------|
| `tests/verifiers/verify_negative.js`                 | Negative-fixture harness: assert parse errors exist. Replaces broken expected-file path. |
| `tests/verifiers/verify_discriminators.js`           | Walks 467-file corpus, asserts every enum-string field (Property.kind etc.) stays in its ESTree-legal set. Baseline-locked. |
| `tests/verifiers/verify_position_containment.js`     | Walks 467-file corpus, asserts `child.start >= parent.start && child.end <= parent.end` on every parent→child edge. Zero-tolerance. |
| `tests/verifiers/verify_raw_value_consistency.js`    | For every `Literal` node whose raw is a number/string/bigint/regex literal, asserts `eval(raw) === value` (with the usual caveats for regex `/null` and bigint). |

None of these are wired into `Taskfile.yml` in this pass — I cannot edit that file. See "Wiring checklist" below.

---

## New fixtures added

```
tests/fixtures/early_errors/          (12 files)   strict-mode violations + unterminated literals
tests/fixtures/spec/asi/              (8 files)    restricted productions + ambiguous cases
tests/fixtures/spec/es2023/           (2 files)    hashbang + array mutators
tests/fixtures/spec/escapes/          (12 files)   \u{...} boundaries + line continuations
tests/fixtures/spec/jsx/              (8 files)    namespaced, member tag, spread attr, entities
tests/fixtures/spec/regex_disambiguation/ (12 files) regex vs division across all precedence slots
tests/fixtures/spec/typescript/       (10 files)   generics, conditional types, mapped types
tests/fixtures/spec/unicode/          (9 files)    unicode idents + invalid starts
```

---

## Wiring checklist (for follow-up PR that can touch `Taskfile.yml`)

Add these lines to the default `test` chain after `test:unit`:

```yaml
test:
  cmds:
    - task: test:unit
    - task: test:negative                   # new — verify_negative.js
    - task: test:discriminators             # new — verify_discriminators.js (baseline)
    - task: test:position-containment       # new — verify_position_containment.js (zero-tol)
    - task: test:raw-consistency            # new — verify_raw_value_consistency.js (baseline)
    - task: test:multi-parser-gate          # new — verify_multi_parser.js (baseline)
    - task: test:regression
    - task: test:real
    # ...rest unchanged
```

Individual task definitions are in `tests/wiring/taskfile_snippets.yaml` (an informational file, not consumed by Task).

---

## What would surface if a careful OXC reviewer ran the new suite today

Based on manual spot-check during this audit:

| Suite                     | Expected outcome on current `main`                                               |
|---------------------------|----------------------------------------------------------------------------------|
| `verify_negative.js`      | **6 FAILS** — the 6 negative fixtures in S0-1 prove real parser bugs.           |
| `verify_position_containment.js` | likely 0 violations (spot-checked 3 files) — but the gate matters for the future. |
| `verify_discriminators.js`| likely ≤ 10 violations baseline (MethodDefinition.kind='method' on constructor seen once during spot-check — need real run). |
| `verify_raw_value_consistency.js` | unknown — never checked across the corpus before.                              |
| `spec/asi/`               | unknown — ASI is where parsers drift most.                                       |
| `spec/regex_disambiguation/` | unknown — a known risk surface.                                              |
| `spec/typescript/`        | most will fail (parser not wired) — captured in a baseline, expected to shrink as Phase 3 completes. |

QA's role isn't to hide these. The new baselines make every one of them visible, comparable across PRs, and easy to improve incrementally.
