// Classifier logic unit tests for the coverage harness.
// Tests only through public API functions.
package coverage

import "core:testing"

// ============================================================================
// test262 frontmatter
// ============================================================================

@(test)
test_frontmatter_empty :: proc(t: ^testing.T) {
	meta := parse_test262_frontmatter("var x = 1;", context.temp_allocator)
	testing.expect(t, meta.phase == .None)
}

@(test)
test_frontmatter_parse :: proc(t: ^testing.T) {
	code := `/*---
negative:
  phase: parse
  type: SyntaxError
---*/
var x = ;
`
	meta := parse_test262_frontmatter(code, context.temp_allocator)
	testing.expect(t, meta.phase == .Parse)
}

@(test)
test_frontmatter_early :: proc(t: ^testing.T) {
	code := `/*---
negative:
  phase: early
  type: SyntaxError
---*/
let x=1;let x=2;
`
	meta := parse_test262_frontmatter(code, context.temp_allocator)
	testing.expect(t, meta.phase == .Early)
}

@(test)
test_frontmatter_resolution :: proc(t: ^testing.T) {
	code := `/*---
negative:
  phase: resolution
  type: ReferenceError
---*/
import {x} from 'm';
`
	meta := parse_test262_frontmatter(code, context.temp_allocator)
	testing.expect(t, meta.phase == .Resolution)
}

@(test)
test_frontmatter_runtime :: proc(t: ^testing.T) {
	code := `/*---
negative:
  phase: runtime
  type: TypeError
---*/
null.foo();
`
	meta := parse_test262_frontmatter(code, context.temp_allocator)
	testing.expect(t, meta.phase == .Runtime)
}

@(test)
test_frontmatter_module_flag :: proc(t: ^testing.T) {
	code := `/*---
flags: [module]
---*/
`
	meta := parse_test262_frontmatter(code, context.temp_allocator)
	testing.expect(t, .Module in meta.flags)
}

@(test)
test_frontmatter_no_frontmatter :: proc(t: ^testing.T) {
	meta := parse_test262_frontmatter("// just a comment\nvar x = 1;\n", context.temp_allocator)
	testing.expect(t, meta.phase == .None)
}

// ============================================================================
// babel
// ============================================================================

@(test)
test_babel_plugins_has :: proc(t: ^testing.T) {
	opts := BabelOptions{plugins = {"typescript", "jsx"}}
	testing.expect(t, babel_plugins_has(opts, "typescript"))
	testing.expect(t, !babel_plugins_has(opts, "flow"))
}

@(test)
test_babel_skip_path :: proc(t: ^testing.T) {
	testing.expect(t, babel_skip_path("/vendor/babel/experimental/decorators/input.js"))
	testing.expect(t, !babel_skip_path("/vendor/babel/es2022/class-properties/input.js"))
}

// ============================================================================
// stats
// ============================================================================

@(test)
test_stats_compute :: proc(t: ^testing.T) {
	records := []CoverageRecord{
		{should_fail = false, result = {tag = .Passed}},
		{should_fail = true,  result = {tag = .CorrectError}},
	}
	s := stats_compute(records)
	testing.expect(t, s.parsed_positives == 1)
	testing.expect(t, s.passed_positives == 1)
	testing.expect(t, s.passed_negatives == 1)
}

@(test)
test_result_passed :: proc(t: ^testing.T) {
	testing.expect(t,  result_passed({tag = .Passed}))
	testing.expect(t,  result_passed({tag = .CorrectError}))
	testing.expect(t, !result_passed({tag = .ParseError}))
}

// ============================================================================
// names
// ============================================================================

@(test)
test_suite_names :: proc(t: ^testing.T) {
	testing.expect(t, suite_name(.Test262) == "test262")
	testing.expect(t, suite_name(.Babel) == "babel")
	testing.expect(t, suite_name(.TypeScript) == "typescript")
}

@(test)
test_tool_names :: proc(t: ^testing.T) {
	testing.expect(t, tool_name(.Parser) == "parser")
	testing.expect(t, tool_name(.Semantic) == "semantic")
}
