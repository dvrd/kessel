package kessel

// Use resolved bindings for assignment rules. A parameter, catch variable or
// local declaration can shadow any spelling from an outer scope.
lint_check_semantic_rules :: proc(l: ^Linter, ctx: ^LintContext, program: ^Program) {
	by_kind := #partial [SymbolKind]LintRule{
		.Function = .L2050_NoFuncAssign, .Class = .L2049_NoClassAssign,
		.Const = .L2055_NoConstAssign, .Using = .L2055_NoConstAssign,
		.Import = .L2048_NoImportAssign, .CatchParam = .L2029_NoExAssign,
		.Param = .L4058_NoParamReassign,
	}
	globals := lint_rule_enabled(l, .L2047_NoGlobalAssign)
	undef := lint_rule_enabled(l, .L2006_NoUndef)
	unused := lint_rule_enabled(l, .L2007_NoUnusedVars)
	shadow := lint_rule_enabled(l, .L2008_NoShadow)
	prefer_const := lint_rule_enabled(l, .L4012_PreferConst)
	needed := globals || undef || unused || shadow || prefer_const || len(l.regexp_calls) != 0
	if len(l.console_members) > 0 || len(l.getter_descriptors) > 0 { needed = true }
	if len(l.global_reports) > 0 || len(l.object_calls) > 0 || len(l.replace_all_calls) > 0 { needed = true }
	if len(l.then_references) > 0 || len(l.unassigned) > 0 || len(l.set_sizes) > 0 { needed = true }
	if lint_rule_enabled(l, .L2056_NoShadowRestrictedNames) { needed = true }
	hooks := ctx.dependencies != nil && len(ctx.dependencies.calls) > 0
	if hooks { needed = true }
	for &rule in by_kind {
		if rule == .None { continue }
		if lint_rule_enabled(l, rule) { needed = true } else { rule = .None }
	}
	if !needed { return }

	property_uses: SemanticPropertyUses
	sites: ^SemanticPropertyUses
	if by_kind[.Import] != .None && lint_has_namespace_import(program) { sites = &property_uses }
	let_uses: SemanticLetUses
	let_sites := &let_uses if prefer_const else nil
	model := semantic_build(program, l.source, ctx.lang, l.allocator, property_uses=sites, let_uses=let_sites)
	if prefer_const { lint_check_prefer_const(l, &model, let_sites) }
	if hooks { lint_check_hook_dependencies(l, &model, ctx.dependencies) }
	for ref in model.refs {
		if len(l.global_reports) > 0 && ref.resolved == SYMBOL_UNRESOLVED {
			lint_flush_global_reports(l, ref.start)
		}
		if len(l.getter_descriptors) > 0 && ref.resolved == SYMBOL_UNRESOLVED {
			if entry, found := l.getter_descriptors[ref.start]; found { lint_getter_check_descriptors(l, entry) }
		}
		if ref.resolved == SYMBOL_UNRESOLVED && ref.name == "console" {
			if loc, present := l.console_members[ref.start]; present {
				rule := LintRule.L4037_NoConsole
				lint_report(l, loc.start, loc.end, rule, lint_rule_info(rule).default_message)
			}
		}
		if ref.kind != .Write && ref.kind != .ReadWrite { continue }
		if ref.resolved == SYMBOL_UNRESOLVED {
			if globals && lint_global_readonly(&l.globals, ref.name) {
				rule := LintRule.L2047_NoGlobalAssign
				lint_report(l, ref.start, ref.end, rule, lint_rule_info(rule).default_message)
			}
			continue
		}
		symbol := &model.symbols[ref.resolved]
		for kind in symbol.kinds {
			rule := by_kind[kind]
			if rule == .None { continue }
			// TypeScript import-equals declarations have their own assignment semantics.
			if kind == .Import && .Readonly not_in symbol.flags { continue }
			// The class and const rules label the declaration first, then the write.
			start, end := ref.start, ref.end
			if rule == .L2049_NoClassAssign || rule == .L2055_NoConstAssign {
				start, end = symbol.decl_start, symbol.decl_end
			}
			lint_report(l, start, end, rule, lint_rule_info(rule).default_message)
		}
	}
	lint_parity_semantic(l, &model)
	if sites != nil { lint_check_namespace_mutations(l, &model, sites) }
	if len(l.regexp_calls) != 0 { lint_check_regexp_calls(l, &model) }
	if undef || unused || shadow { lint_scope_pass(l, &model, ctx.lang, undef, unused, shadow) }
}

lint_has_namespace_import :: proc(program: ^Program) -> bool {
	for statement in program.body {
		if statement == nil { continue }
		decl, found := statement^.(^ImportDeclaration)
		if !found || decl == nil || decl.import_kind == .Type { continue }
		for item in decl.specifiers {
			if item != nil {
				if _, namespace := item^.(ImportNamespaceSpecifier); namespace { return true }
			}
		}
	}
	return false
}

lint_namespace_reference :: proc(model: ^SemanticModel, scope: ScopeId, expr: ^Expression) -> ^Identifier {
	node := semantic_runtime_expression(expr)
	if node == nil { return nil }
	id, ok := node^.(^Identifier)
	if !ok || id == nil { return nil }
	symbol := semantic_lookup(model, scope, id.name)
	if symbol == SYMBOL_UNRESOLVED || .NamespaceImport not_in model.symbols[symbol].flags { return nil }
	return id
}

lint_check_namespace_mutations :: proc(l: ^Linter, model: ^SemanticModel, uses: ^SemanticPropertyUses) {
	rule := LintRule.L2048_NoImportAssign
	info := lint_rule_info(rule)
	for write in uses.writes {
		if lint_namespace_reference(model, write.scope, write.member.object) == nil { continue }
		loc := write.member.loc
		lint_report(l, loc.start, loc.end, rule, info.default_message)
	}
	for site in uses.calls {
		id := lint_namespace_reference(model, site.scope, site.argument)
		if id == nil { continue }
		member := site.member
		if member == nil || member.object == nil || member.property == nil { continue }
		receiver, ok := member.object^.(^Identifier)
		if !ok || receiver == nil { continue }
		if receiver.name != "Object" && receiver.name != "Reflect" { continue }
		if semantic_lookup(model, site.scope, receiver.name) != SYMBOL_UNRESOLVED { continue }
		name: string
		if member.computed {
			constant, known := lint_constant_string(member.property)
			if !known { continue }
			name = constant
		} else if property, named := member.property^.(^Identifier); named && property != nil {
			name = property.name
		}
		mutates := false
		switch name {
		case "setPrototypeOf", "defineProperty": mutates = true
		case "assign", "defineProperties", "freeze": mutates = receiver.name == "Object"
		case "deleteProperty", "set": mutates = receiver.name == "Reflect"
		}
		if mutates { lint_report(l, id.loc.start, id.loc.end, rule, info.default_message) }
	}
}
