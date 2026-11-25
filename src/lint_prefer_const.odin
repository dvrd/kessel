package kessel

import "core:encoding/json"
import "core:fmt"
import "core:strings"

LintPreferConstOptions :: struct { destructuring_all, ignore_read_before_assign: bool }

lint_prefer_const_options :: proc(options: []json.Value) -> (LintPreferConstOptions, bool) {
	settings: LintPreferConstOptions
	if len(options) == 0 { return settings, true }
	if len(options) != 1 { return {}, false }
	object, ok := options[0].(json.Object)
	if !ok { return {}, false }
	for key, value in object {
		switch key {
		case "destructuring":
			mode, valid := value.(json.String)
			if !valid || (mode != "any" && mode != "all") { return {}, false }
			settings.destructuring_all = mode == "all"
		case "ignoreReadBeforeAssign":
			setting, valid := value.(json.Boolean)
			if !valid { return {}, false }
			settings.ignore_read_before_assign = setting
		case: return {}, false
		}
	}
	return settings, true
}

LintLetBinding :: struct {
	writes, last_write: u32,
	first_read: u32, // One-based byte offset, with zero reserved for no read.
	cross_scope_write, can_initialize: bool,
}

lint_check_prefer_const :: proc(l: ^Linter, model: ^SemanticModel, uses: ^SemanticLetUses) {
	if len(uses.declarations) == 0 { return }
	bindings := make([]LintLetBinding, len(model.symbols), l.allocator)
	for ref in model.refs {
		if ref.resolved == SYMBOL_UNRESOLVED || ref.kind == .Type { continue }
		use := &bindings[ref.resolved]
		if ref.kind != .Write && (use.first_read == 0 || ref.start + 1 < use.first_read) {
			use.first_read = ref.start + 1
		}
		if ref.kind == .Read { continue }
		use.writes += 1
		use.last_write = ref.start
		symbol := &model.symbols[ref.resolved]
		if ref.scope != symbol.scope {
			// A rest binding is visible in the immediate function body even
			// when parameter initializers require a separate environment.
			scope := &model.scopes[ref.scope]
			if .RestParameter not_in symbol.flags || scope.kind != .FunctionBody || scope.parent != symbol.scope {
				use.cross_scope_write = true
			}
		}
	}
	targets := make([dynamic]SymbolId, l.allocator)
	for assignment in uses.assignments {
		clear(&targets)
		if !lint_let_targets(model, assignment.scope, assignment.target, &targets) { continue }
		valid := true
		for id in targets {
			symbol := &model.symbols[id]
			if (.Param in symbol.kinds && .RestParameter not_in symbol.flags) || bindings[id].cross_scope_write ||
			   (l.prefer_const.destructuring_all && bindings[id].writes > 1) {
				valid = false
				break
			}
		}
		if valid {
			for id in targets { bindings[id].can_initialize = true }
		}
	}
	names := make([dynamic]string, l.allocator)
	for site in uses.declarations {
		clear(&targets)
		lint_prefer_const_declaration(l, model, bindings, site, uses.eval_scopes[site.scope], &names, &targets)
	}
}

// Only the target of an assignment counts as a write. Computed keys and
// defaults may read other names, and a property target cannot become a binding.
lint_let_targets :: proc(model: ^SemanticModel, scope: ScopeId, target: ^Expression, out: ^[dynamic]SymbolId) -> bool {
	node := semantic_runtime_expression(target)
	if node == nil { return false }
	#partial switch e in node^ {
	case ^Identifier:
		if e == nil { return false }
		id := semantic_lookup(model, scope, e.name)
		if id != SYMBOL_UNRESOLVED { append(out, id) }
		return true
	case ^ArrayExpression:
		if e == nil || !lint_let_pattern_scope(model, scope) { return false }
		for item in e.elements {
			if value, ok := item.?; ok && !lint_let_targets(model, scope, value, out) { return false }
		}
		return true
	case ^ObjectExpression:
		if e == nil || !lint_let_pattern_scope(model, scope) { return false }
		for property in e.properties {
			if !lint_let_targets(model, scope, property.value, out) { return false }
		}
		return true
	case ^AssignmentExpression: return e != nil && lint_let_targets(model, scope, e.left, out)
	case ^SpreadElement: return e != nil && lint_let_targets(model, scope, e.argument, out)
	}
	return false
}

lint_let_pattern_scope :: proc(model: ^SemanticModel, scope: ScopeId) -> bool {
	if model.scopes[scope].kind != .Block { return true }
	parent := model.scopes[scope].parent
	for _ in 0..<len(model.scopes) {
		if model.scopes[parent].kind == .ForEach { return true }
		if semantic_is_function_scope(model, parent) { break }
		parent = model.scopes[parent].parent
	}
	return false
}

lint_let_candidate :: proc(use: LintLetBinding, symbol: ^Symbol, initialized, ignore_read_before_assign: bool) -> bool {
	point := symbol.decl_start if initialized else use.last_write
	if ignore_read_before_assign && use.first_read > 0 && use.first_read - 1 < point { return false }
	if initialized { return use.writes == 0 }
	return use.writes == 1 && !use.cross_scope_write && use.can_initialize
}

lint_prefer_const_declaration :: proc(l: ^Linter, model: ^SemanticModel, bindings: []LintLetBinding, site: SemanticLetDeclaration, direct_eval: bool, names: ^[dynamic]string, reports: ^[dynamic]SymbolId) {
	rule :: LintRule.L4012_PreferConst
	decl := site.declaration
	scope_kind := model.scopes[site.scope].kind
	for_each := site.loop_head && scope_kind == .ForEach
	all_eligible := true
	fixable := .Fix in l.fix_kinds && !direct_eval
	for item in decl.declarations {
		clear(names)
		collect_pattern_bound_names_list(item.id, names)
		first := len(reports^)
		initialized := item.init != nil || for_each
		if !initialized { fixable = false }
		for name in names^ {
			id := semantic_lookup(model, site.scope, name)
			if id == SYMBOL_UNRESOLVED { continue }
			if lint_let_candidate(bindings[id], &model.symbols[id], initialized, l.prefer_const.ignore_read_before_assign) {
				append(reports, id)
			}
		}
		if len(reports^) - first != len(names^) {
			all_eligible = false
			if l.prefer_const.destructuring_all { resize(reports, first) }
		}
	}
	if !all_eligible && site.loop_head && scope_kind == .For && len(decl.declarations) > 1 { return }
	keyword := Loc{decl.loc.start, decl.loc.start + 3}
	// A single keyword governs every declarator. Editing a mixed declaration
	// would turn a later legal assignment into a runtime TypeError.
	fixable = fixable && all_eligible && int(keyword.end) <= len(l.source) && l.source[keyword.start:keyword.end] == "let"
	for id in reports^ {
		symbol := &model.symbols[id]
		loc := lint_let_identifier_span(l, symbol)
		lint_report(l, loc.start, loc.end, rule, fmt.tprintf("`%s` is never reassigned.", symbol.name))
		if fixable { l.fixes[{rule, loc}] = {keyword, "const"} }
	}
}

lint_let_identifier_span :: proc(l: ^Linter, symbol: ^Symbol) -> Loc {
	raw := l.source[symbol.decl_start:symbol.decl_end]
	if strings.has_prefix(raw, symbol.name) {
		return {symbol.decl_start, symbol.decl_start + u32(len(symbol.name))}
	}
	// Escapes can make the source spelling longer than the cooked name. A TS
	// annotation can extend the node beyond the name. Use the actual token.
	lex: Lexer
	init_lexer(&lex, raw, l.allocator)
	return {symbol.decl_start, symbol.decl_start + lex.cur.end}
}
