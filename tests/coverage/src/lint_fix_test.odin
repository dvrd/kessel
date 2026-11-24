package coverage

import "core:testing"
import kessel "../../../src"

// Two competing diagnostics start at byte one. The shorter edit wins,
// the overlapping edit is skipped and the adjacent one still applies.
@(test)
test_lint_fix_conflicts :: proc(t: ^testing.T) {
	l := kessel.init_linter(context.temp_allocator)
	l.source = "abcdef"
	l.fixes = make(map[kessel.LintFixKey]kessel.LintEdit, context.temp_allocator)
	rule := kessel.LintRule.L1003_Eqeqeq
	edits := [?]kessel.LintEdit{{{1, 4}, "LONG"}, {{3, 5}, "Y"}, {{1, 3}, "X"}, {{2, 5}, "SKIP"}}
	for e in edits {
		kessel.lint_report(&l, e.span.start, e.span.end, rule, "")
		l.fixes[{rule, e.span}] = e
	}
	// Absence from the remaining diagnostics makes even an otherwise valid edit ineligible.
	l.fixes[{rule, {0, 1}}] = {{0, 1}, "SUPPRESSED"}
	result := kessel.lint_fix_apply(&l)
	defer delete(result.output)
	testing.expect_value(t, result.changed, true)
	testing.expect_value(t, string(result.output), "aXYf")
}
