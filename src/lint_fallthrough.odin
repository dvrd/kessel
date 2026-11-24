package kessel

import "core:encoding/json"
import "core:mem"
import "core:strings"
import "core:text/regex"

LintFallthroughOptions :: struct {
	comment_pattern: ^regex.Regular_Expression,
	allow_empty_case, report_unused_comment: bool,
}

lint_fallthrough_options :: proc(options: []json.Value, allocator: mem.Allocator) -> (LintFallthroughOptions, bool) {
	settings: LintFallthroughOptions
	if len(options) == 0 { return settings, true }
	if len(options) != 1 { return {}, false }
	object, ok := options[0].(json.Object)
	if !ok { return {}, false }
	for key, value in object {
		switch key {
		case "allowEmptyCase", "reportUnusedFallthroughComment":
			enabled, valid := value.(json.Boolean)
			if !valid { return {}, false }
			if key == "allowEmptyCase" { settings.allow_empty_case = bool(enabled) }
			else { settings.report_unused_comment = bool(enabled) }
		case "commentPattern":
			if _, absent := value.(json.Null); absent { continue }
			source, valid := value.(json.String)
			if !valid { return {}, false }
			// An empty pattern matches every non-directive comment, including an empty one.
			pattern := string(source) if len(source) > 0 else "^"
			compiled, err := regex.create(pattern, {.Unicode, .Case_Insensitive, .No_Capture}, allocator, context.temp_allocator)
			if err != nil { return {}, false }
			settings.comment_pattern = new(regex.Regular_Expression, allocator)
			settings.comment_pattern^ = compiled
		case: return {}, false
		}
	}
	return settings, true
}

lint_check_no_fallthrough :: proc(l: ^Linter, statement: ^SwitchStatement) {
	if statement == nil || !lint_rule_enabled(l, .L2045_NoFallthrough) { return }
	for i in 1..<len(statement.cases) {
		clause, next := &statement.cases[i-1], &statement.cases[i]
		assert(clause.loc.start <= next.loc.start)
		if clause.loc.end > next.loc.start || next.loc.start > u32(len(l.source)) { continue }
		if len(clause.consequent) == 0 {
			// Adjacent empty labels form a group. A second line break separates the cases.
			if l.fallthrough_options.allow_empty_case { continue }
			gap := l.source[clause.loc.end:next.loc.start]
			first := strings.index_byte(gap, '\n')
			if first < 0 || strings.index_byte(gap[first+1:], '\n') < 0 { continue }
		}
		_, exits := cfg_first_terminator(clause.consequent[:], l.allocator)
		if exits && !l.fallthrough_options.report_unused_comment { continue }
		comment, annotated := lint_fallthrough_annotation(l, clause, next.loc.start)
		if exits {
			if annotated {
				lint_report(l, comment.start, comment.end, .L2045_NoFallthrough, "fallthrough comment is unused because this case exits")
			}
		} else if !annotated {
			label := "expected a 'break' or 'return' before 'case'"
			if next.test == nil { label = "expected a 'break' or 'return' before 'default'" }
			lint_report(l, next.loc.start, next.loc.end, .L2045_NoFallthrough, label)
		}
	}
}

// A sole block can carry its annotation inside the braces or after the block.
// An earlier comment separated from the boundary by another statement has no effect.
@(private="file")
lint_fallthrough_annotation :: proc(l: ^Linter, clause: ^SwitchCase, next_start: u32) -> (Loc, bool) {
	if len(l.comments) == 0 { return {}, false }
	start := clause.loc.end
	if len(clause.consequent) == 1 && !statement_inner_nil(clause.consequent[0]) {
		if block, ok := clause.consequent[0]^.(^BlockStatement); ok {
			start = block.loc.start
			if len(block.body) > 0 { start = get_statement_loc(block.body[len(block.body)-1]).end }
			inside := Loc{start, block.loc.end}
			if lint_fallthrough_comment_matches(l, inside) { return inside, true }
		}
	}
	span := Loc{start, next_start}
	return span, lint_fallthrough_comment_matches(l, span)
}

@(private="file")
lint_fallthrough_comment_matches :: proc(l: ^Linter, span: Loc) -> bool {
	if span.start >= span.end { return false }
	end := codegen_comment_lower_bound(l.comments, span.end)
	if end == 0 { return false }
	comment := &l.comments[end-1]
	if comment.start < span.start || comment.end > span.end { return false }
	content := strings.trim_space(comment.value)
	if strings.has_prefix(content, "eslint-") || strings.has_prefix(content, "oxlint-") { return false }
	if pattern := l.fallthrough_options.comment_pattern; pattern != nil {
		_, matches := regex.match_and_allocate_capture(pattern^, content, context.temp_allocator, context.temp_allocator)
		return matches
	}
	markers :: [4]string{"falls through", "fall through", "fallsthrough", "fallthrough"}
	for marker in markers {
		if len(content) == len(marker) && strings.equal_fold(content, marker) { return true }
	}
	return false
}
