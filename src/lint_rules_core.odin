package kessel

import "core:encoding/json"
import "core:fmt"
import "core:strings"

// ESLint core rules whose node selection and diagnostic ranges follow the
// pinned oxlint implementation. tests/lint/upstream_parity.json records the
// measured agreement for each of them.

// Settings for rules that accept options. The zero value is each rule's default
// except where lint_rule_options_default says otherwise.
LintRuleOptions :: struct {
	negation_ordering:       bool, // no-unsafe-negation enforceForOrderingRelations
	isnan_skip_switch:       bool, // use-isnan enforceForSwitchCase = false
	isnan_index_of:          bool, // use-isnan enforceForIndexOf
	typeof_string_literals:  bool, // valid-typeof requireStringLiterals
	cond_assign_always:      bool, // no-cond-assign "always"
	self_assign_skip_props:  bool, // no-self-assign props = false
	optional_chain_arithmetic:   bool, // no-unsafe-optional-chaining disallowArithmeticOperators
	rename_ignore_destructuring: bool, // no-useless-rename ignoreDestructuring
	rename_ignore_import:        bool, // no-useless-rename ignoreImport
	rename_ignore_export:        bool, // no-useless-rename ignoreExport
	boolean_cast_inner:          bool, // no-extra-boolean-cast enforceForInnerExpressions
	eval_no_indirect:            bool, // no-eval allowIndirect = false
	unused_allow_short_circuit:  bool, // no-unused-expressions allowShortCircuit
	unused_allow_ternary:        bool, // no-unused-expressions allowTernary
	unused_allow_tagged:         bool, // no-unused-expressions allowTaggedTemplates
	unused_enforce_jsx:          bool, // no-unused-expressions enforceForJSX
	this_alias_destructuring:    bool, // no-this-alias allowDestructuring = false
	this_alias_names:            map[string]bool, // no-this-alias allowedNames
	restricted_names_skip_global_this: bool, // no-shadow-restricted-names reportGlobalThis = false
	empty_allow_catch:           bool, // no-empty allowEmptyCatch
	void_allow_statement:        bool, // no-void allowAsStatement
	labels_allow_loop:           bool, // no-labels allowLoop
	labels_allow_switch:         bool, // no-labels allowSwitch
	multi_assign_ignore_non_declaration: bool, // no-multi-assign ignoreNonDeclaration
	plusplus_allow_for:          bool, // no-plusplus allowForLoopAfterthoughts
	triple_slash: struct { lib, path, types: LintReferenceOption }, // triple-slash-reference
}

lint_rule_takes_options :: proc(rule: LintRule) -> bool {
	#partial switch rule {
	case .L2010_NoUnsafeNegation, .L2018_UseIsnan, .L2027_ValidTypeof, .L2009_NoCondAssign,
	     .L2012_NoSelfAssign, .L2035_NoUnsafeOptionalChaining, .L4027_NoUselessRename,
	     .L2042_NoExtraBooleanCast, .L4008_NoEval, .L4006_NoUnusedExpressions, .L3016_NoThisAlias,
	     .L2056_NoShadowRestrictedNames, .L1001_NoEmpty, .L4045_NoVoid, .L4100_NoLabels,
	     .L4101_NoMultiAssign, .L4048_NoPlusplus, .L3020_TripleSlashReference:
		return true
	}
	return false
}

lint_option_bool :: proc(values: []json.Value, key: string, fallback: bool) -> bool {
	if len(values) == 0 { return fallback }
	object, is_object := values[0].(json.Object)
	if !is_object { return fallback }
	value, is_bool := object[key].(json.Boolean)
	return bool(value) if is_bool else fallback
}

// The strings listed under `key` (or its alias) of the first option object.
lint_option_names :: proc(values: []json.Value, key, alias: string) -> map[string]bool {
	names := make(map[string]bool)
	if len(values) == 0 { return names }
	object, is_object := values[0].(json.Object)
	if !is_object { return names }
	list, is_list := object[key].(json.Array)
	if !is_list { list, is_list = object[alias].(json.Array) }
	if !is_list { return names }
	for item in list {
		if name, is_string := item.(json.String); is_string { names[string(name)] = true }
	}
	return names
}

lint_reference_option :: proc(values: []json.Value, key: string) -> LintReferenceOption {
	object, is_object := values[0].(json.Object)
	if !is_object { return .Default }
	word, is_string := object[key].(json.String)
	if !is_string { return .Default }
	switch string(word) {
	case "always":        return .Always
	case "never":         return .Never
	case "prefer-import": return .Prefer_Import
	}
	return .Default
}

lint_rule_options_apply :: proc(options: ^LintRuleOptions, rule: LintRule, values: []json.Value) {
	assert(options != nil)
	assert(len(values) > 0)
	#partial switch rule {
	case .L2010_NoUnsafeNegation:
		options.negation_ordering = lint_option_bool(values, "enforceForOrderingRelations", false)
	case .L2018_UseIsnan:
		options.isnan_skip_switch = !lint_option_bool(values, "enforceForSwitchCase", true)
		options.isnan_index_of = lint_option_bool(values, "enforceForIndexOf", false)
	case .L2027_ValidTypeof:
		options.typeof_string_literals = lint_option_bool(values, "requireStringLiterals", false)
	case .L2042_NoExtraBooleanCast:
		options.boolean_cast_inner = lint_option_bool(values, "enforceForInnerExpressions", false) ||
			lint_option_bool(values, "enforceForLogicalOperands", false)
	case .L3020_TripleSlashReference:
		options.triple_slash.lib = lint_reference_option(values, "lib")
		options.triple_slash.path = lint_reference_option(values, "path")
		options.triple_slash.types = lint_reference_option(values, "types")
	case .L1001_NoEmpty:
		options.empty_allow_catch = lint_option_bool(values, "allowEmptyCatch", false)
	case .L4045_NoVoid:
		options.void_allow_statement = lint_option_bool(values, "allowAsStatement", false)
	case .L4100_NoLabels:
		options.labels_allow_loop = lint_option_bool(values, "allowLoop", false)
		options.labels_allow_switch = lint_option_bool(values, "allowSwitch", false)
	case .L4101_NoMultiAssign:
		options.multi_assign_ignore_non_declaration = lint_option_bool(values, "ignoreNonDeclaration", false)
	case .L4048_NoPlusplus:
		options.plusplus_allow_for = lint_option_bool(values, "allowForLoopAfterthoughts", false)
	case .L2056_NoShadowRestrictedNames:
		options.restricted_names_skip_global_this = !lint_option_bool(values, "reportGlobalThis", true)
	case .L3016_NoThisAlias:
		options.this_alias_destructuring = !lint_option_bool(values, "allowDestructuring", true)
		options.this_alias_names = lint_option_names(values, "allowedNames", "allowNames")
	case .L4006_NoUnusedExpressions:
		options.unused_allow_short_circuit = lint_option_bool(values, "allowShortCircuit", false)
		options.unused_allow_ternary = lint_option_bool(values, "allowTernary", false)
		options.unused_allow_tagged = lint_option_bool(values, "allowTaggedTemplates", false)
		options.unused_enforce_jsx = lint_option_bool(values, "enforceForJSX", false)
	case .L4008_NoEval:
		options.eval_no_indirect = !lint_option_bool(values, "allowIndirect", true)
	case .L2035_NoUnsafeOptionalChaining:
		options.optional_chain_arithmetic = lint_option_bool(values, "disallowArithmeticOperators", false)
	case .L4027_NoUselessRename:
		options.rename_ignore_destructuring = lint_option_bool(values, "ignoreDestructuring", false)
		options.rename_ignore_import = lint_option_bool(values, "ignoreImport", false)
		options.rename_ignore_export = lint_option_bool(values, "ignoreExport", false)
	case .L2012_NoSelfAssign:
		options.self_assign_skip_props = !lint_option_bool(values, "props", true)
	case .L2009_NoCondAssign:
		mode, is_string := values[0].(json.String)
		options.cond_assign_always = is_string && string(mode) == "always"
	}
}

// lint_parity_stmt and lint_parity_expr run before the walk descends into a
// node. They own the rules that need the ancestor stack or a statement kind
// the older per-node checks never received.
lint_parity_stmt :: proc(l: ^Linter, ctx: ^LintContext, stmt: ^Statement) {
	#partial switch node in stmt^ {
	case ^IfStatement:      lint_cond_assign_test(l, node.test, false)
	case ^WhileStatement:   lint_cond_assign_test(l, node.test, false)
	case ^DoWhileStatement: lint_cond_assign_test(l, node.test, false)
	case ^ForStatement:
		if test, ok := node.test.?; ok { lint_cond_assign_test(l, test, false) }
	case ^SwitchStatement:
		lint_check_isnan_switch(l, node)
		lint_check_case_declarations(l, node)
	case ^ExpressionStatement:
		lint_check_unused_expression(l, node)
	case ^ReturnStatement:
		lint_check_setter_return(l, node)
		lint_check_unsafe_finally(l, stmt)
	case ^ContinueStatement:
		lint_check_no_continue(l, node)
		lint_check_unsafe_finally(l, stmt)
	case ^ThrowStatement, ^BreakStatement:
		lint_check_unsafe_finally(l, stmt)
	case ^ImportDeclaration:
		lint_check_rename_module(l, stmt)
	case ^ExportNamedDeclaration:
		lint_check_rename_module(l, stmt)
		lint_check_thenable_export(l, node)
	case ^ClassDeclaration:
		lint_check_thenable_class(l, &node.expr)
	case ^ForInStatement:
		if target, ok := node.left_expr.?; ok { lint_check_rename_target(l, target) }
	case ^ForOfStatement:
		if target, ok := node.left_expr.?; ok { lint_check_rename_target(l, target) }
	}
	lint_check_optional_chain_stmt(l, stmt)
	lint_check_no_empty(l, stmt)
	lint_check_no_labels(l, stmt)
}

lint_parity_expr :: proc(l: ^Linter, ctx: ^LintContext, expr: ^Expression) {
	#partial switch node in expr^ {
	case ^ConditionalExpression:
		lint_cond_assign_test(l, node.test, true)
	case ^AssignmentExpression:
		lint_cond_assign_nested(l, node)
		if lint_rule_enabled(l, .L4027_NoUselessRename) { lint_check_rename_target(l, node.left) }
		lint_check_thenable_assignment(l, node)
		lint_check_no_multi_assign(l, node)
	case ^CallExpression:
		lint_check_isnan_index_of(l, node)
		lint_check_oxc_call(l, node)
		lint_check_unicorn_call(l, node)
	case ^NewExpression:
		lint_check_oxc_new(l, node)
		lint_check_new_array(l, node)
		lint_check_no_new(l, node)
	case ^AwaitExpression:
		lint_check_unnecessary_await(l, node)
	case ^ObjectExpression:
		lint_check_thenable_object(l, node)
		// The walk skips plain keys, and a quoted key is a string literal too.
		for prop in node.properties {
			if prop.key != nil && !prop.computed { lint_check_no_script_url(l, prop.key) }
		}
	case ^ClassExpression:
		lint_check_thenable_class(l, node)
	case ^BinaryExpression:
		lint_check_oxc_binary(l, node)
		lint_check_no_eq_null(l, node)
	case ^UnaryExpression:
		lint_check_no_void(l, node)
	case ^UpdateExpression:
		lint_check_no_plusplus(l, node)
	case ^StringLiteral:
		lint_check_no_script_url(l, expr)
		lint_check_nonoctal_escape(l, node)
	case ^TemplateLiteral:
		lint_check_no_script_url(l, expr)
	case ^LogicalExpression:
		lint_check_double_comparisons(l, node)
		lint_check_fallback_in_spread(l, node)
		lint_check_useless_length(l, node)
	case ^MemberExpression:
		lint_check_set_size(l, node)
	case ^Identifier:
		lint_check_eval_reference(l, node)
		lint_check_arguments_method(l, node)
	}
	lint_check_typescript_expr(l, ctx, expr)
	lint_check_extra_boolean_cast(l, expr)
	lint_check_optional_chain_expr(l, expr)
}

// Skips whitespace and comments from `position`.
lint_skip_trivia :: proc(source: string, position: u32) -> u32 {
	index := int(position)
	for index < len(source) {
		if lint_is_space(source[index]) {
			index += 1
		} else if strings.has_prefix(source[index:], "//") {
			for index < len(source) && source[index] != '\n' { index += 1 }
		} else if strings.has_prefix(source[index:], "/*") {
			close := strings.index(source[index + 2:], "*/")
			if close < 0 { return u32(len(source)) }
			index += close + 4
		} else {
			break
		}
	}
	return u32(index)
}

// no-with: the range covers the keyword only.
lint_check_no_with :: proc(l: ^Linter, v: ^WithStatement) {
	if v == nil || !lint_rule_enabled(l, .L2028_NoWith) { return }
	lint_emit(l, {v.loc.start, v.loc.start + 4}, .L2028_NoWith)
}

// no-caller: `arguments.callee` and `arguments.caller`, reported on the property.
lint_check_no_caller :: proc(l: ^Linter, e: ^MemberExpression) {
	if e == nil || e.computed || !lint_rule_enabled(l, .L4023_NoCallerCallee) { return }
	property := lint_identifier(e.property)
	if property == nil { return }
	if property.name != "callee" && property.name != "caller" { return }
	if lint_is_specific_id(e.object, "arguments") { lint_emit(l, property.loc, .L4023_NoCallerCallee) }
}

lint_check_no_proto :: proc(l: ^Linter, e: ^MemberExpression) {
	if e == nil || !lint_rule_enabled(l, .L4018_NoProto) { return }
	if name, ok := lint_static_property_name(e); ok && name == "__proto__" {
		lint_emit(l, e.loc, .L4018_NoProto)
	}
}

lint_check_no_iterator :: proc(l: ^Linter, e: ^MemberExpression) {
	if e == nil || !lint_rule_enabled(l, .L4022_NoIterator) { return }
	if name, ok := lint_static_property_name(e); ok && name == "__iterator__" {
		lint_emit(l, e.loc, .L4022_NoIterator)
	}
}

// no-var reports the keyword. Ambient TypeScript declarations cannot use let.
lint_check_no_var :: proc(l: ^Linter, d: ^VariableDeclaration) {
	if d.kind != .Var || !lint_rule_enabled(l, .L1004_NoVar) { return }
	for node in l.ancestors {
		stmt, is_stmt := node.(^Statement)
		if !is_stmt { continue }
		if module, ok := stmt^.(^TSModuleDeclaration); ok && module != nil {
			if module.declare || module.global || module.kind == .Global { return }
		}
	}
	offset := strings.index(l.source[d.loc.start:d.loc.end], "var")
	if offset < 0 { return }
	start := d.loc.start + u32(offset)
	lint_emit(l, {start, start + 3}, .L1004_NoVar)
}

LINT_SPARSE_LABELS_MAX :: 10

// no-sparse-arrays labels the comma of every hole. Ten or more holes collapse
// into one label on the array.
lint_check_sparse_array :: proc(l: ^Linter, e: ^ArrayExpression) {
	if e == nil || !lint_rule_enabled(l, .L1002_NoSparseArrays) { return }
	holes := 0
	first: u32
	cursor := e.loc.start + 1
	for element in e.elements {
		if item, present := element.?; present && item != nil {
			cursor = lint_skip_trivia(l.source, lint_expr_loc(item).end)
		} else {
			cursor = lint_skip_trivia(l.source, cursor)
			if holes == 0 { first = cursor }
			holes += 1
		}
		// Step over the comma that ends this element.
		if int(cursor) < len(l.source) && l.source[cursor] == ',' { cursor += 1 }
	}
	if holes == 0 { return }
	if holes < LINT_SPARSE_LABELS_MAX {
		lint_emit(l, {first, first}, .L1002_NoSparseArrays)
	} else if e.loc.end - e.loc.start < 50 {
		lint_emit(l, e.loc, .L1002_NoSparseArrays)
	} else {
		lint_emit(l, {e.loc.start, e.loc.start}, .L1002_NoSparseArrays)
	}
}

// no-async-promise-executor reports the `async` keyword of the executor.
lint_check_async_promise :: proc(l: ^Linter, e: ^NewExpression) {
	if e == nil || !lint_rule_enabled(l, .L2013_NoAsyncPromiseExecutor) { return }
	if len(e.arguments) == 0 || !lint_is_specific_id(e.callee, "Promise") { return }
	executor := lint_inner(e.arguments[0])
	if executor == nil { return }
	start: u32
	#partial switch fn in executor^ {
	case ^ArrowFunctionExpression:
		if !fn.async { return }
		start = fn.loc.start
	case ^FunctionExpression:
		if !fn.async { return }
		start = fn.loc.start
	case:
		return
	}
	lint_emit(l, {start, start + 5}, .L2013_NoAsyncPromiseExecutor)
}

// no-duplicate-case: the primary range is the first of the two equal tests.
lint_check_duplicate_case :: proc(l: ^Linter, v: ^SwitchStatement) {
	if v == nil || !lint_rule_enabled(l, .L2014_NoDuplicateCase) { return }
	previous := make([dynamic]^Expression, 0, len(v.cases), context.temp_allocator)
	for clause in v.cases {
		raw, has_test := clause.test.?
		if !has_test || raw == nil { continue }
		test := lint_unparen(raw)
		earlier: ^Expression
		for candidate in previous {
			if lint_content_eq(l, candidate, test) { earlier = candidate; break }
		}
		if earlier != nil {
			lint_emit(l, lint_expr_loc(earlier), .L2014_NoDuplicateCase)
		} else {
			append(&previous, test)
		}
	}
}

// no-useless-catch: a handler whose first statement rethrows its parameter.
lint_check_useless_catch :: proc(l: ^Linter, h: CatchClause) {
	if !lint_rule_enabled(l, .L2016_NoUselessCatch) { return }
	pattern, has_param := h.param.?
	if !has_param || len(h.body.body) == 0 || h.body.body[0] == nil { return }
	param, is_identifier := pattern.(^Identifier)
	if !is_identifier || param == nil { return }
	throw, is_throw := h.body.body[0]^.(^ThrowStatement)
	if !is_throw || throw == nil { return }
	thrown := lint_identifier(throw.argument)
	if thrown != nil && thrown.name == param.name { lint_emit(l, param.loc, .L2016_NoUselessCatch) }
}

lint_check_new_native :: proc(l: ^Linter, e: ^NewExpression) {
	if e == nil || !lint_rule_enabled(l, .L2019_NoNewNativeNonconstructor) { return }
	callee := lint_identifier(e.callee)
	if callee == nil || (callee.name != "Symbol" && callee.name != "BigInt") { return }
	lint_report_if_global(l, callee, {e.loc.start, e.loc.start + 3}, .L2019_NoNewNativeNonconstructor)
}

lint_binary_is_compare :: proc(operator: BinaryOperator) -> bool {
	return operator == .Lt || operator == .LtEq || operator == .Gt || operator == .GtEq
}

lint_binary_is_equality :: proc(operator: BinaryOperator) -> bool {
	return operator == .Eq || operator == .NotEq || operator == .StrictEq || operator == .StrictNotEq
}

// `Object.name` through dots, brackets or an optional chain.
lint_is_member_access :: proc(expr: ^Expression, object, property: string) -> bool {
	inner := lint_inner(expr)
	if inner == nil { return false }
	if chain, ok := inner^.(^ChainExpression); ok && chain != nil { inner = chain.expression }
	if inner == nil { return false }
	member, ok := inner^.(^MemberExpression)
	if !ok || member == nil || !lint_is_specific_id(member.object, object) { return false }
	name, static := lint_static_property_name(member)
	return static && name == property
}

lint_expr_is_nan :: proc(e: ^Expression) -> bool {
	return lint_is_specific_id(e, "NaN") || lint_is_member_access(e, "Number", "NaN")
}

lint_expr_is_neg_zero :: proc(e: ^Expression) -> bool {
	inner := lint_inner(e)
	if inner == nil { return false }
	unary, ok := inner^.(^UnaryExpression)
	if !ok || unary == nil || unary.operator != .Minus || unary.argument == nil { return false }
	#partial switch literal in unary.argument^ {
	case ^NumericLiteral: return literal.value == 0
	case ^BigIntLiteral:  return lint_bigint_is_zero(literal.raw)
	}
	return false
}

lint_bigint_is_zero :: proc(raw: string) -> bool {
	digits := strings.trim_suffix(raw, "n")
	if len(digits) > 2 && digits[0] == '0' {
		switch digits[1] { case 'x', 'X', 'o', 'O', 'b', 'B': digits = digits[2:] }
	}
	for char in digits {
		if char != '0' && char != '_' { return false }
	}
	return len(digits) > 0
}

// The comparison rules that only look at one BinaryExpression.
lint_check_binary :: proc(l: ^Linter, e: ^BinaryExpression) {
	if e == nil || e.left == nil || e.right == nil { return }
	compare := lint_binary_is_compare(e.operator)
	comparison := compare || lint_binary_is_equality(e.operator)
	if lint_rule_enabled(l, .L2010_NoUnsafeNegation) {
		relational := e.operator == .In || e.operator == .Instanceof
		if relational || (l.options.negation_ordering && compare) {
			if unary, ok := e.left^.(^UnaryExpression); ok && unary != nil && unary.operator == .LogicalNot {
				lint_emit(l, unary.loc, .L2010_NoUnsafeNegation)
			}
		}
	}
	if !comparison { return }
	if lint_rule_enabled(l, .L2011_NoCompareNegZero) {
		if lint_expr_is_neg_zero(e.left) || lint_expr_is_neg_zero(e.right) {
			lint_emit(l, e.loc, .L2011_NoCompareNegZero)
		}
	}
	if lint_rule_enabled(l, .L2018_UseIsnan) {
		if lint_expr_is_nan(e.left) { lint_emit(l, lint_expr_loc(e.left), .L2018_UseIsnan) }
		if lint_expr_is_nan(e.right) { lint_emit(l, lint_expr_loc(e.right), .L2018_UseIsnan) }
	}
	if lint_rule_enabled(l, .L2017_NoSelfCompare) {
		if lint_content_eq(l, lint_unparen(e.left), lint_unparen(e.right)) {
			lint_emit(l, lint_expr_loc(e.left), .L2017_NoSelfCompare)
		}
	}
}

lint_check_isnan_switch :: proc(l: ^Linter, v: ^SwitchStatement) {
	if v == nil || l.options.isnan_skip_switch || !lint_rule_enabled(l, .L2018_UseIsnan) { return }
	if lint_expr_is_nan(v.discriminant) { lint_emit(l, lint_expr_loc(v.discriminant), .L2018_UseIsnan) }
	for clause in v.cases {
		test, has_test := clause.test.?
		if has_test && lint_expr_is_nan(test) { lint_emit(l, lint_expr_loc(test), .L2018_UseIsnan) }
	}
}

// use-isnan enforceForIndexOf: `x.indexOf(NaN)` never finds anything.
lint_check_isnan_index_of :: proc(l: ^Linter, e: ^CallExpression) {
	if !l.options.isnan_index_of || !lint_rule_enabled(l, .L2018_UseIsnan) { return }
	if len(e.arguments) == 0 || len(e.arguments) > 2 { return }
	callee := lint_inner(e.callee)
	if callee == nil { return }
	if chain, ok := callee^.(^ChainExpression); ok && chain != nil { callee = chain.expression }
	if callee == nil { return }
	member, is_member := callee^.(^MemberExpression)
	if !is_member { return }
	name, static := lint_static_property_name(member)
	if !static || (name != "indexOf" && name != "lastIndexOf") { return }
	if _, spread := e.arguments[0]^.(^SpreadElement); spread { return }
	argument := lint_inner(e.arguments[0])
	if argument == nil { return }
	if sequence, ok := argument^.(^SequenceExpression); ok {
		if len(sequence.expressions) == 0 { return }
		argument = lint_inner(sequence.expressions[len(sequence.expressions) - 1])
	}
	if lint_expr_is_nan(argument) { lint_emit(l, lint_expr_loc(argument), .L2018_UseIsnan) }
}

lint_is_typeof :: proc(e: ^Expression) -> bool {
	if e == nil { return false }
	unary, ok := e^.(^UnaryExpression)
	return ok && unary != nil && unary.operator == .Typeof
}

lint_valid_typeof_name :: proc(name: string) -> bool {
	switch name {
	case "bigint", "boolean", "function", "number", "object", "string", "symbol", "undefined":
		return true
	}
	return false
}

// valid-typeof runs once for each `typeof` operand of an equality, exactly as
// the reference visits each UnaryExpression child.
lint_check_valid_typeof :: proc(l: ^Linter, e: ^BinaryExpression) {
	if e == nil || !lint_rule_enabled(l, .L2027_ValidTypeof) { return }
	if !lint_binary_is_equality(e.operator) || e.left == nil || e.right == nil { return }
	visits := int(lint_is_typeof(e.left)) + int(lint_is_typeof(e.right))
	if visits == 0 { return }
	sibling := e.left
	if _, unary := e.left^.(^UnaryExpression); unary { sibling = e.right }
	loc := lint_expr_loc(sibling)
	for _ in 0..<visits {
		#partial switch node in sibling^ {
		case ^StringLiteral:
			if !lint_valid_typeof_name(node.value) { lint_emit(l, loc, .L2027_ValidTypeof) }
			continue
		case ^TemplateLiteral:
			if len(node.expressions) == 0 && len(node.quasis) == 1 {
				if !lint_valid_typeof_name(node.quasis[0].raw) { lint_emit(l, loc, .L2027_ValidTypeof) }
				continue
			}
		case ^Identifier:
			// A shadowed `undefined` falls through to the string-literal check.
			if node.name == "undefined" && !l.options.typeof_string_literals {
				lint_report_if_global(l, node, loc, .L2027_ValidTypeof)
				continue
			}
		}
		if l.options.typeof_string_literals && !lint_is_typeof(sibling) { lint_emit(l, loc, .L2027_ValidTypeof) }
	}
}

// no-cond-assign reports the assignment operator.
lint_cond_assign_emit :: proc(l: ^Linter, e: ^AssignmentExpression) {
	start, end := lint_expr_loc(e.left).end, lint_expr_loc(e.right).start
	operator := lint_assignment_operator_text(e.operator)
	if end < start || int(end) > len(l.source) { return }
	offset := max(strings.index(l.source[start:end], operator), 0)
	start += u32(offset)
	lint_emit(l, {start, start + u32(len(operator))}, .L2009_NoCondAssign)
}

lint_assignment_operator_text :: proc(operator: AssignmentOperator) -> string {
	switch operator {
	case .Assign:            return "="
	case .AddAssign:         return "+="
	case .SubAssign:         return "-="
	case .MulAssign:         return "*="
	case .DivAssign:         return "/="
	case .ModAssign:         return "%="
	case .PowAssign:         return "**="
	case .ShiftLeftAssign:   return "<<="
	case .ShiftRightAssign:  return ">>="
	case .ShiftRightUAssign: return ">>>="
	case .BitOrAssign:       return "|="
	case .BitXorAssign:      return "^="
	case .BitAndAssign:      return "&="
	case .AssignLogicalAnd:  return "&&="
	case .AssignLogicalOr:   return "||="
	case .AssignNullish:     return "??="
	}
	return "="
}

// Statement tests count an assignment only when it is not parenthesized.
// A conditional expression's test always looks through its parentheses.
lint_cond_assign_test :: proc(l: ^Linter, test: ^Expression, conditional: bool) {
	if test == nil || !lint_rule_enabled(l, .L2009_NoCondAssign) { return }
	target := test
	if conditional || l.options.cond_assign_always { target = lint_inner(test) }
	if target == nil { return }
	if assignment, ok := target^.(^AssignmentExpression); ok && assignment != nil {
		lint_cond_assign_emit(l, assignment)
	}
}

// "always" mode also reports an assignment nested anywhere inside a test.
lint_cond_assign_nested :: proc(l: ^Linter, e: ^AssignmentExpression) {
	if !l.options.cond_assign_always || !lint_rule_enabled(l, .L2009_NoCondAssign) { return }
	for index := len(l.ancestors) - 2; index >= 0; index -= 1 {
		test: ^Expression
		whole: Loc
		switch node in l.ancestors[index] {
		case ^Statement:
			#partial switch stmt in node^ {
			case ^IfStatement:      test = stmt.test
			case ^WhileStatement:   test = stmt.test
			case ^DoWhileStatement: test = stmt.test
			case ^ForStatement:     test, _ = stmt.test.?
			case ^BlockStatement, ^FunctionDeclaration: return
			}
		case ^Expression:
			#partial switch expr in node^ {
			case ^ConditionalExpression: whole = expr.loc
			case ^FunctionExpression, ^ArrowFunctionExpression: return
			}
		case ^BlockStatement:
			return
		}
		if test != nil { whole = lint_expr_loc(test) }
		if whole.end > whole.start && whole.start <= e.loc.start && e.loc.end <= whole.end {
			lint_cond_assign_emit(l, e)
			return
		}
	}
}

// The name oxlint derives for a property key, or false for a dynamic key.
lint_property_static_name :: proc(key: ^Expression, computed: bool) -> (name: string, ok: bool) {
	if key == nil { return "", false }
	#partial switch node in key^ {
	case ^Identifier:
		if computed { return "", false }
		return node.name, true
	case ^StringLiteral:  return node.value, true
	case ^NumericLiteral: return lint_number_name(lint_numeric_value(node)), true
	case ^BigIntLiteral:  return strings.trim_suffix(node.value, "n"), true
	case ^NullLiteral:    return "null", true
	case ^RegExpLiteral:  return fmt.tprintf("/%s/%s", node.pattern, node.flags), true
	case ^TemplateLiteral:
		if len(node.expressions) == 0 && len(node.quasis) == 1 { return node.quasis[0].raw, true }
	}
	return "", false
}

// The parser stores a legacy octal literal such as `012` with its decimal
// reading. Keys compare by the value the engine uses, which is octal.
lint_numeric_value :: proc(literal: ^NumericLiteral) -> f64 {
	raw := literal.raw
	if len(raw) < 2 || raw[0] != '0' { return literal.value }
	value: f64
	for char in raw[1:] {
		if char < '0' || char > '7' { return literal.value }
		value = value * 8 + f64(char - '0')
	}
	return value
}

// A BigInt property key is recorded with an empty range. Scan its token for the end.
lint_key_loc :: proc(l: ^Linter, key: ^Expression) -> Loc {
	loc := lint_expr_loc(key)
	if _, big := key^.(^BigIntLiteral); !big || loc.end > loc.start { return loc }
	loc.end = loc.start
	for int(loc.end) < len(l.source) {
		char := l.source[loc.end]
		word := (char >= '0' && char <= '9') || (char >= 'a' && char <= 'z') || (char >= 'A' && char <= 'Z')
		if !word && char != '_' { break }
		loc.end += 1
	}
	return loc
}

// Integral values print without a fraction, which is how equal numeric keys
// such as `1` and `1.0` collide.
lint_number_name :: proc(value: f64) -> string {
	if value == f64(i64(value)) && abs(value) < 1e15 { return fmt.tprintf("%d", i64(value)) }
	return fmt.tprintf("%v", value)
}

LintSeenKey :: struct { kind: PropertyKind, loc: Loc }

// no-dupe-keys: a getter and a setter may share a name. Anything else that
// repeats a name is reported on the earlier key.
lint_check_dupe_keys :: proc(l: ^Linter, e: ^ObjectExpression) {
	if e == nil || len(e.properties) <= 1 || !lint_rule_enabled(l, .L2002_NoDupeKeys) { return }
	seen := make(map[string]LintSeenKey, len(e.properties), context.temp_allocator)
	for prop in e.properties {
		if prop.key == nil { continue }
		name, static := lint_property_static_name(prop.key, prop.computed)
		if !static { continue }
		kind := prop.kind if prop.kind != .Method else PropertyKind.Init
		plain := prop.kind == .Init && !prop.computed && !prop.shorthand
		if name == "__proto__" && plain { continue }
		key_loc := lint_key_loc(l, prop.key)
		previous, repeated := seen[name]
		seen[name] = {kind, key_loc}
		if !repeated { continue }
		if previous.kind == .Init || kind == .Init || previous.kind == kind {
			lint_emit(l, previous.loc, .L2002_NoDupeKeys)
		}
	}
}

lint_split_logical :: proc(out: ^[dynamic]^Expression, expr: ^Expression, operator: LogicalOperator) {
	if expr == nil { return }
	// A chain such as `a || b || c` nests on the left without limit, so the
	// left spine is followed in a loop. Right operands are bounded by the
	// parser's nesting limit and may recurse.
	rights := make([dynamic]^Expression, 0, 4, context.temp_allocator)
	current := expr
	for {
		current = lint_unparen(current)
		if current == nil { break }
		node, is_logical := current^.(^LogicalExpression)
		if !is_logical || node.operator != operator { break }
		append(&rights, node.right)
		current = node.left
	}
	if current != nil { append(out, current) }
	#reverse for right in rights { lint_split_logical(out, right, operator) }
}

// `a && b` equals `b && a` for this rule. Other shapes compare structurally.
lint_else_if_equal :: proc(l: ^Linter, a, b: ^Expression) -> bool {
	if !lint_compare_enter(l) { return false }
	defer l.compare_depth -= 1
	left, left_logical := a^.(^LogicalExpression)
	right, right_logical := b^.(^LogicalExpression)
	if left_logical && right_logical && left.operator == right.operator && left.operator != .NullishCoalescing {
		if lint_else_if_equal(l, left.left, right.left) && lint_else_if_equal(l, left.right, right.right) { return true }
		return lint_else_if_equal(l, left.left, right.right) && lint_else_if_equal(l, left.right, right.left)
	}
	return lint_content_eq(l, a, b)
}

lint_else_if_subset :: proc(l: ^Linter, a, b: []^Expression) -> bool {
	for first in a {
		found := false
		for second in b {
			if lint_else_if_equal(l, first, second) { found = true; break }
		}
		if !found { return false }
	}
	return true
}

lint_or_operands :: proc(expr: ^Expression) -> [dynamic][dynamic]^Expression {
	context.allocator = context.temp_allocator
	alternatives: [dynamic]^Expression
	lint_split_logical(&alternatives, expr, .Or)
	operands: [dynamic][dynamic]^Expression
	for alternative in alternatives {
		terms: [dynamic]^Expression
		lint_split_logical(&terms, alternative, .And)
		append(&operands, terms)
	}
	return operands
}

// no-dupe-else-if: a branch is dead when the earlier tests of its chain
// already cover every way its own test can be true. Each `||` operand of the
// test is removed once an earlier test implies it.
lint_check_dupe_else_if :: proc(l: ^Linter, v: ^IfStatement) {
	if v == nil || v.test == nil || !lint_rule_enabled(l, .L2023_NoDupeElseIf) { return }
	context.allocator = context.temp_allocator
	conditions: [dynamic]^Expression
	append(&conditions, v.test)
	if logical, ok := v.test^.(^LogicalExpression); ok && logical.operator == .And {
		lint_split_logical(&conditions, v.test, .And)
	}
	remaining: [dynamic][dynamic][dynamic]^Expression
	for condition in conditions { append(&remaining, lint_or_operands(condition)) }
	current := v
	for index := len(l.ancestors) - 2; index >= 0; index -= 1 {
		stmt, is_stmt := l.ancestors[index].(^Statement)
		if !is_stmt { return }
		parent, is_if := stmt^.(^IfStatement)
		if !is_if || parent == nil { return }
		alternate, has_alternate := parent.alternate.?
		if !has_alternate || alternate == nil { return }
		child, child_is_if := alternate^.(^IfStatement)
		if !child_is_if || child != current { return }
		current = parent
		earlier := lint_or_operands(parent.test)
		for &operands in remaining {
			kept: [dynamic][dynamic]^Expression
			for operand in operands {
				covered := false
				for candidate in earlier {
					if lint_else_if_subset(l, candidate[:], operand[:]) { covered = true; break }
				}
				if !covered { append(&kept, operand) }
			}
			operands = kept
			if len(kept) == 0 {
				lint_emit(l, lint_expr_loc(parent.test), .L2023_NoDupeElseIf)
				return
			}
		}
	}
}

// no-empty-static-block: a comment inside the braces counts as content.
lint_check_empty_static_block :: proc(l: ^Linter, elem: ClassElement) {
	if elem.kind != .StaticBlock || !lint_rule_enabled(l, .L4030_NoEmptyStaticBlock) { return }
	value, has_value := elem.value.?
	if !has_value || value == nil { return }
	block, is_block := value^.(^FunctionExpression)
	if !is_block || block == nil || len(block.body.body) != 0 { return }
	if lint_has_comment_between(l, elem.loc.start, elem.loc.end) { return }
	lint_emit(l, elem.loc, .L4030_NoEmptyStaticBlock)
}
