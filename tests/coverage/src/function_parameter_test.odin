// `function_parameter_view` (src/function_parameter.odin): one view of a
// parameter's binding target and default value, whichever of the parser's
// two representations holds the default.
//
// Method: the same parameter list is parsed as a function declaration, a
// function expression, a method, an arrow, an async arrow and three
// TypeScript arrows. The test first pins how the parser stores each (so it
// fails loudly if that ever changes and this accessor becomes redundant),
// then requires the view to be identical for all of them.
package coverage

import "core:testing"

import kessel "../../../src"

@(private = "file")
ParameterSource :: struct {
	source:            string,
	lang:              kessel.Lang,
	// True when the parser keeps the default in an AssignmentPattern.
	stored_in_pattern: bool,
}

// Parameters of the first function-like thing in the program.
@(private = "file")
first_parameters :: proc(program: ^kessel.Program) -> []kessel.FunctionParameter {
	if len(program.body) == 0 { return nil }
	#partial switch statement in program.body[0] {
	case ^kessel.FunctionDeclaration:
		return statement.params[:]
	case ^kessel.ExpressionStatement:
		expression := statement.expression
		if group, grouped := expression.(^kessel.ParenthesizedExpression); grouped {
			expression = group.expression
		}
		#partial switch e in expression {
		case ^kessel.FunctionExpression:      return e.params[:]
		case ^kessel.ArrowFunctionExpression: return e.params[:]
		case ^kessel.ObjectExpression:
			if len(e.properties) == 0 { return nil }
			method, is_function := e.properties[0].value.(^kessel.FunctionExpression)
			if is_function { return method.params[:] }
		}
	}
	return nil
}

@(test)
test_function_parameter_view_is_uniform :: proc(t: ^testing.T) {
	sources := [?]ParameterSource{
		{"function f(a = 1, b, {c} = d, ...e) {}", .JS, false},
		{"(function (a = 1, b, {c} = d, ...e) {});", .JS, false},
		{"({ m(a = 1, b, {c} = d, ...e) {} });", .JS, false},
		// Reinterpreted from a parenthesised expression.
		{"((a = 1, b, {c} = d, ...e) => 0);", .JS, true},
		// Parsed as a parameter list from the start.
		{"(async (a = 1, b, {c} = d, ...e) => 0);", .JS, false},
		{"((a: number = 1, b, {c} = d, ...e) => 0);", .TS, false},
		{"(<T,>(a = 1, b, {c} = d, ...e) => 0);", .TS, false},
		{"((a = 1, b, {c} = d, ...e): number => 0);", .TS, false},
	}
	for parameter_source in sources {
		source := parameter_source.source
		job: kessel.ParseJob
		config := kessel.ParseConfig{lang_override = parameter_source.lang}
		if !testing.expect(t, kessel.parse_job_open_inline(&job, source, config, "params")) {
			continue
		}
		defer kessel.parse_job_close(&job)
		kessel.parse_job_run(&job)
		parsed := len(job.parser.errors) == 0
		if !testing.expectf(t, parsed, "%q does not parse", source) { continue }
		parameters := first_parameters(job.program)
		if !testing.expectf(t, len(parameters) == 4, "%q: %d parameters", source, len(parameters)) {
			continue
		}

		// The representation this accessor hides.
		_, in_pattern := parameters[0].pattern.(^kessel.AssignmentPattern)
		_, in_field := parameters[0].default_val.?
		testing.expectf(t, in_pattern == parameter_source.stored_in_pattern, "%q: storage", source)
		testing.expectf(t, in_field == !parameter_source.stored_in_pattern, "%q: storage", source)

		// `a = 1`: an identifier target and a default.
		first := kessel.function_parameter_view(&parameters[0])
		target, is_identifier := first.target.(^kessel.Identifier)
		if testing.expectf(t, is_identifier, "%q: target is the bare identifier", source) {
			testing.expect_value(t, target.name, "a")
		}
		if testing.expectf(t, first.default_value != nil, "%q: default present", source) {
			literal, is_number := first.default_value.(^kessel.NumericLiteral)
			if testing.expect(t, is_number) { testing.expect_value(t, literal.value, 1) }
		}
		testing.expect(t, kessel.function_parameter_has_default(&parameters[0]))

		// `b`: no default.
		second := kessel.function_parameter_view(&parameters[1])
		_, second_is_identifier := second.target.(^kessel.Identifier)
		testing.expect(t, second_is_identifier)
		testing.expect(t, second.default_value == nil)
		testing.expect(t, !kessel.function_parameter_has_default(&parameters[1]))

		// `{c} = d`: a destructuring target and a default.
		third := kessel.function_parameter_view(&parameters[2])
		_, is_object_pattern := third.target.(^kessel.ObjectPattern)
		testing.expectf(t, is_object_pattern, "%q: target is the object pattern", source)
		if testing.expect(t, third.default_value != nil) {
			_, default_is_identifier := third.default_value.(^kessel.Identifier)
			testing.expect(t, default_is_identifier)
		}

		// `...e`: a rest element, never a default.
		fourth := kessel.function_parameter_view(&parameters[3])
		_, is_rest := fourth.target.(^kessel.RestElement)
		testing.expectf(t, is_rest, "%q: target is the rest element", source)
		testing.expect(t, fourth.default_value == nil)
	}
}
