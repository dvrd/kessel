# Swarm plan — next OXC-parity session

Task files for delegating the recommended next-session items (from
`SESSION_REPORT.md` Recommended next session list) to Claude Haiku 4.5
via the `execute-task` skill.

## Waves

### Wave 1 — parallel, file-disjoint (safe to run all 3 at once)

| # | Task file | Kind | Files touched |
|---|-----------|------|---------------|
| 1 | `01-jsx-nested.md` | `bug-fix` | `src/parser.odin` (JSX section only) + `tests/baselines/unit_known_failures.txt` |
| 2 | `02-unicode-escape.md` | `implement-feature` | `src/lexer.odin`, small `src/parser.odin` ident sites, `src/token.odin` |
| 3 | `03-err-structured.md` | `refactor` | `src/main.odin` (error emitter + CLI) |

These three touch different files / sections and share no state. Launch
all three in parallel.

### Wave 2 — sequential (after Wave 1 is green), each touches `src/main.odin`

| # | Task file | Kind | Files touched |
|---|-----------|------|---------------|
| 4 | `04-est-loc.md` | `implement-feature` | `src/main.odin` (emit_span_fields + CLI) |
| 5 | `05-esm-module-record.md` | `implement-feature` | `src/ast.odin` + `src/parser.odin` (import/export sites) + `src/main.odin` |
| 6 | `06-ambient-module.md` | `bug-fix` | `src/parser.odin` (module decl + var decl) |

Wave 2 needs to be serial because 4 and 5 both add new output to
`main.odin`'s emitter; 6 touches `parser.odin`'s var-declarator which
Wave 1 item 2 also touches (identifier sites). Merge conflicts are
cheaper to avoid than to resolve.

### Wave 3 — orchestrator-led (NOT delegated to Haiku)

Two items are too architectural / forensic for a bounded Haiku delegation.
They need cross-cutting design decisions and diff-against-OXC iteration:

- **`<` trial-parse** (TS-C1c `<T>(x) => x` + TS-C6 `<Type>expr`).
  Requires saving lexer state, attempting `<Type>` + `(params) =>` or
  `<Type>expr`, and falling back to JSX on failure. Cuts across
  `parse_primary_expr`, `parse_arrow_function`, and `lexer.odin` state
  snapshot helpers. Best done in a careful, single-author session.

- **TS-ESTree shape alignment** for the 10 `spec/typescript/*` fixtures.
  Requires running OXC on each fixture, diffing field-by-field, and
  applying targeted emitter tweaks (likely `type_parameters: null`
  default when `astType: 'ts'`). Too forensic for a single Haiku prompt.

## Launching

```bash
# Wave 1, in parallel, three sessions:
SKILL=~/.agents/skills/execute-task/scripts/run.sh

$SKILL bug-fix           .swarm/01-jsx-nested.md        --log /tmp/kessel-w1-01.log | tee /tmp/kessel-w1-01.sess
$SKILL implement-feature .swarm/02-unicode-escape.md    --log /tmp/kessel-w1-02.log | tee /tmp/kessel-w1-02.sess
$SKILL refactor          .swarm/03-err-structured.md    --log /tmp/kessel-w1-03.log | tee /tmp/kessel-w1-03.sess

# Poll each:
for s in /tmp/kessel-w1-0{1,2,3}.sess; do
    SESSION=$(head -1 "$s")
    agent-tui screenshot --session "$SESSION" --format text | tail -30
done
```

Follow the single-poll-per-turn rule in `~/.agents/skills/execute-task/SKILL.md`:
no `sleep` loops, no `agent-tui wait`.

## After a task reports DONE

1. `tail -25 "$LOG" | grep -qE '^\s*DONE\s*$'` — confirm.
2. Run the verification commands yourself — don't trust Haiku's self-report.
3. `git diff` to review.
4. Commit with a short conventional-commit message.
5. `agent-tui kill --session <id>` to free the slot.
6. `context_tag <task>-done`.

## When all waves land

Update `OXC_PARITY.md` to reflect all closed items (original ~23 from
last session + whatever of these 6 lands).
