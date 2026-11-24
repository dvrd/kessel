// JSX AST details that downstream compilers rely on.
//
// Each test parses an inline source the way a library consumer does
// (`parse_job_open_inline` + `parse_job_run`) and asserts on the typed AST
// rather than on emitted JSON, so a regression shows up as the field that
// moved. Covered:
//
//   * a mismatched closing tag is reported on the closing tag's name;
//   * `{...xs}` in child position is a `JSXSpreadChild`;
//
// tests/verifiers/verify_jsx_ast.js checks the same contract against the
// pinned reference parsers.
package coverage

import "core:testing"

import kessel "../../../src"

// Parse `source` as JSX and return the JSX element of its first statement.
// `job` stays open so the caller can read errors and the arena-backed AST.
@(private = "file")
jsx_open :: proc(t: ^testing.T, job: ^kessel.ParseJob, source: string) -> ^kessel.JSXElement {
	config := kessel.ParseConfig{lang_override = kessel.Lang.JSX}
	if !testing.expect(t, kessel.parse_job_open_inline(job, source, config, "inline.jsx")) {
		return nil
	}
	kessel.parse_job_run(job)
	if job.program == nil || len(job.program.body) == 0 { return nil }
	statement, is_expression := job.program.body[0].(^kessel.ExpressionStatement)
	if !is_expression || statement.expression == nil { return nil }
	element, _ := statement.expression.(^kessel.JSXElement)
	return element
}

@(private = "file")
JSXErrorCase :: struct {
	source: string,
	start:  u32,
	end:    u32,
	code:   kessel.ErrorCode,
}

// Spans are the ones oxc-parser 0.127.0 labels for the same sources.
@(test)
test_jsx_error_spans :: proc(t: ^testing.T) {
	cases := [?]JSXErrorCase{
		// Mismatched closing tag: the closing tag's whole name.
		{"<p></div>;",            5,  8, .K3063_JSXInvalid},
		{"<a.b></a.c>;",          7, 10, .K3063_JSXInvalid},
		{"<a:b></a:c>;",          7, 10, .K3063_JSXInvalid},
		{"<a></b.c>;",            5,  8, .K3063_JSXInvalid},
		{"<a>\n  <b></c>\n</a>;", 11, 12, .K3063_JSXInvalid},
	}
	for error_case in cases {
		job: kessel.ParseJob
		jsx_open(t, &job, error_case.source)
		defer kessel.parse_job_close(&job)
		if !testing.expectf(t, len(job.parser.errors) >= 1, "no error for %q", error_case.source) {
			continue
		}
		first := job.parser.errors[0]
		testing.expectf(
			t, first.start == error_case.start && first.end == error_case.end,
			"%q: error spans [%d, %d), want [%d, %d)",
			error_case.source, first.start, first.end, error_case.start, error_case.end,
		)
		testing.expect_value(t, first.code, error_case.code)
	}
}

@(test)
test_jsx_spread_child_node :: proc(t: ^testing.T) {
	source := "<a>{...xs}{ys}{}</a>;"
	job: kessel.ParseJob
	element := jsx_open(t, &job, source)
	defer kessel.parse_job_close(&job)
	if !testing.expect(t, element != nil) { return }
	testing.expect_value(t, len(job.parser.errors), 0)
	if !testing.expect_value(t, len(element.children), 3) { return }

	spread, is_spread := element.children[0].(^kessel.JSXSpreadChild)
	if !testing.expect(t, is_spread, "`{...xs}` must be a JSXSpreadChild") { return }
	// The span covers both braces; the operand is the bare expression.
	testing.expect_value(t, spread.loc, kessel.Loc{start = 3, end = 10})
	operand, is_identifier := spread.expression.(^kessel.Identifier)
	if testing.expect(t, is_identifier, "operand must not be wrapped in a SpreadElement") {
		testing.expect_value(t, operand.name, "xs")
		testing.expect_value(t, operand.loc, kessel.Loc{start = 7, end = 9})
	}

	// Neighbouring containers are unchanged.
	_, is_container := element.children[1].(^kessel.JSXExpressionContainer)
	testing.expect(t, is_container)
	empty, is_empty_container := element.children[2].(^kessel.JSXExpressionContainer)
	if testing.expect(t, is_empty_container) {
		_, is_empty := empty.expression.(^kessel.JSXEmptyExpression)
		testing.expect(t, is_empty)
	}
}
