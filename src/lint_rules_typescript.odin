package kessel

import "core:strings"

// The `typescript` plugin rules that need no type information.

lint_is_typescript :: proc(ctx: ^LintContext) -> bool {
	return ctx.lang == .TS || ctx.lang == .TSX
}

lint_non_null :: proc(expr: ^Expression) -> ^TSNonNullExpression {
	inner := lint_unparen(expr)
	if inner == nil { return nil }
	node, ok := inner^.(^TSNonNullExpression)
	return node if ok else nil
}

lint_check_typescript_expr :: proc(l: ^Linter, ctx: ^LintContext, expr: ^Expression) {
	if !lint_is_typescript(ctx) { return }
	lint_check_extra_non_null(l, expr)
	#partial switch node in expr^ {
	case ^TSNonNullExpression:  lint_check_non_null_optional_chain(l, node)
	case ^TSAsExpression:       lint_check_as_const_expression(l, node)
	case ^AssignmentExpression: lint_check_this_alias_assignment(l, node)
	}
}

// no-extra-non-null-assertion: `a!!` and `a!?.b`. The range is empty and sits
// on the redundant `!`.
lint_check_extra_non_null :: proc(l: ^Linter, expr: ^Expression) {
	if !lint_rule_enabled(l, .L3013_NoExtraNonNullAssertion) { return }
	extra: ^TSNonNullExpression
	#partial switch node in expr^ {
	case ^TSNonNullExpression: extra = lint_non_null(node.expression)
	case ^MemberExpression:    if node.optional { extra = lint_non_null(node.object) }
	case ^CallExpression:      if node.optional { extra = lint_non_null(node.callee) }
	}
	if extra == nil { return }
	lint_emit(l, {extra.loc.end - 1, extra.loc.end - 1}, .L3013_NoExtraNonNullAssertion)
}

lint_parent_is_member_or_call :: proc(l: ^Linter) -> bool {
	parent := lint_ancestor_expr(l, 1)
	if parent == nil { return false }
	#partial switch _ in parent^ {
	case ^MemberExpression, ^CallExpression: return true
	}
	return false
}

// no-non-null-asserted-optional-chain: `a?.b!` asserts away the `undefined`
// that the chain exists to produce. The range is the `!`.
lint_check_non_null_optional_chain :: proc(l: ^Linter, e: ^TSNonNullExpression) {
	if !lint_rule_enabled(l, .L3015_NoNonNullAssertedOptionalChain) { return }
	inner := lint_inner(e.expression)
	if inner == nil { return }
	unsafe := false
	#partial switch node in inner^ {
	case ^ChainExpression:
		if node.expression == nil { return }
		#partial switch element in node.expression^ {
		case ^MemberExpression: unsafe = element.optional
		case ^CallExpression:   unsafe = element.optional
		}
	case ^CallExpression:
		if lint_parent_is_member_or_call(l) { return }
		unsafe = node.optional
		if !unsafe && node.callee != nil {
			if callee, is_member := node.callee^.(^MemberExpression); is_member { unsafe = callee.optional }
		}
	case ^MemberExpression:
		unsafe = node.optional && !lint_parent_is_member_or_call(l)
	}
	if unsafe { lint_emit(l, {e.loc.end - 1, e.loc.end}, .L3015_NoNonNullAssertedOptionalChain) }
}

lint_is_this :: proc(expr: ^Expression) -> bool {
	if expr == nil { return false }
	_, ok := expr^.(^ThisExpression)
	return ok
}

// no-this-alias: `const self = this`. Destructuring `this` is allowed by default.
lint_check_this_alias_declaration :: proc(l: ^Linter, ctx: ^LintContext, d: ^VariableDeclaration) {
	if !lint_is_typescript(ctx) || !lint_rule_enabled(l, .L3016_NoThisAlias) { return }
	for decl in d.declarations {
		init, has_init := decl.init.?
		if !has_init || !lint_is_this(init) { continue }
		if id, simple := decl.id.(^Identifier); simple {
			if !l.options.this_alias_names[id.name] { lint_emit(l, lint_binding_loc(id), .L3016_NoThisAlias) }
		} else if l.options.this_alias_destructuring {
			lint_emit(l, get_pattern_loc(decl.id), .L3016_NoThisAlias)
		}
	}
}

lint_check_this_alias_assignment :: proc(l: ^Linter, e: ^AssignmentExpression) {
	if !lint_rule_enabled(l, .L3016_NoThisAlias) || !lint_is_this(e.right) { return }
	if lint_is_destructuring(e.left) {
		if l.options.this_alias_destructuring { lint_emit(l, lint_expr_loc(lint_unparen(e.left)), .L3016_NoThisAlias) }
		return
	}
	id := lint_identifier(lint_inner(e.left))
	if id != nil && !l.options.this_alias_names[id.name] { lint_emit(l, id.loc, .L3016_NoThisAlias) }
}

lint_type_reference_name :: proc(annotation: Maybe(^TSTypeAnnotation)) -> string {
	wrapper, present := annotation.?
	if !present || wrapper == nil || wrapper.type_annotation == nil { return "" }
	reference, is_reference := wrapper.type_annotation^.(^TSTypeReference)
	if !is_reference || reference == nil { return "" }
	id := lint_identifier(reference.type_name)
	return id.name if id != nil else ""
}

// no-misused-new: an interface that declares `new(): Self` or `constructor()`,
// or a class that declares a bodiless `new(): Self`.
lint_check_misused_new_interface :: proc(l: ^Linter, ctx: ^LintContext, v: ^TSInterfaceDeclaration) {
	if !lint_is_typescript(ctx) || !lint_rule_enabled(l, .L3014_NoMisusedNew) { return }
	for signature in v.body.body {
		if signature == nil { continue }
		#partial switch member in signature^ {
		case TSConstructSignatureDeclaration:
			if lint_type_reference_name(member.return_type) == v.id.name {
				lint_emit(l, {member.loc.start, member.loc.start + 3}, .L3014_NoMisusedNew)
			}
		case TSMethodSignature:
			key := lint_identifier(member.key)
			if key != nil && !member.computed && key.name == "constructor" { lint_emit(l, key.loc, .L3014_NoMisusedNew) }
		}
	}
}

lint_check_misused_new_class :: proc(l: ^Linter, ctx: ^LintContext, cls: ^ClassExpression) {
	if !lint_is_typescript(ctx) || !lint_rule_enabled(l, .L3014_NoMisusedNew) { return }
	name, named := cls.id.?
	if !named { return }
	for elem in cls.body.body {
		if elem.kind == .Field || elem.kind == .StaticBlock || elem.kind == .IndexSignature { continue }
		// The reference matches only an identifier in a computed key, which
		// TypeScript does not accept for a bodiless method, so this never fires.
		if !elem.computed || !lint_is_specific_id(elem.key, "new") { continue }
		value, has_value := elem.value.?
		if !has_value || value == nil { continue }
		fn, is_fn := value^.(^FunctionExpression)
		if !is_fn || !fn.no_body { continue }
		if lint_type_reference_name(fn.return_type) == name.name { lint_emit(l, lint_expr_loc(elem.key), .L3014_NoMisusedNew) }
	}
}

// prefer-namespace-keyword: `module Foo {}` should be `namespace Foo {}`.
lint_check_namespace_keyword :: proc(l: ^Linter, ctx: ^LintContext, v: ^TSModuleDeclaration) {
	if !lint_is_typescript(ctx) || !lint_rule_enabled(l, .L3019_PreferNamespaceKeyword) { return }
	if v.kind != .Module || lint_identifier(v.id) == nil { return }
	lint_emit(l, v.loc, .L3019_PreferNamespaceKeyword)
}

// no-duplicate-enum-values: the earlier initializer is the primary range.
// A repeated number keeps pointing at its first use, a repeated string at
// the most recent one, as in the reference.
lint_check_no_duplicate_enum_values :: proc(l: ^Linter, v: ^TSEnumDeclaration) {
	if v == nil || !lint_rule_enabled(l, .L3008_NoDuplicateEnumValues) { return }
	LintSeenNumber :: struct { value: f64, loc: Loc }
	numbers := make([dynamic]LintSeenNumber, 0, len(v.body.members), context.temp_allocator)
	strings_seen := make(map[string]Loc, len(v.body.members), context.temp_allocator)
	for member in v.body.members {
		init, has_init := member.initializer.?
		if !has_init || init == nil { continue }
		#partial switch literal in init^ {
		case ^NumericLiteral:
			repeated := false
			for seen in numbers {
				if seen.value != literal.value { continue }
				lint_emit(l, seen.loc, .L3008_NoDuplicateEnumValues)
				repeated = true
				break
			}
			if !repeated { append(&numbers, LintSeenNumber{literal.value, literal.loc}) }
		case ^StringLiteral:
			if earlier, repeated := strings_seen[literal.value]; repeated {
				lint_emit(l, earlier, .L3008_NoDuplicateEnumValues)
			}
			strings_seen[literal.value] = literal.loc
		}
	}
}

LintMergeName :: struct { name: string, loc: Loc, class: bool }

lint_merge_declaration :: proc(stmt: ^Statement) -> (entry: LintMergeName, ok: bool) {
	if stmt == nil { return {}, false }
	#partial switch node in stmt^ {
	case ^ClassDeclaration:
		if id, named := node.id.?; named { return {id.name, id.loc, true}, true }
	case ^TSInterfaceDeclaration:
		return {node.id.name, node.id.loc, false}, true
	case ^ExportNamedDeclaration:
		declaration, present := node.declaration.?
		if !present || declaration == nil { return {}, false }
		#partial switch inner in declaration^ {
		case ^ClassDeclaration:
			if id, named := inner.id.?; named { return {id.name, id.loc, true}, true }
		case ^TSInterfaceDeclaration:
			return {inner.id.name, inner.id.loc, false}, true
		}
	}
	return {}, false
}

// no-unsafe-declaration-merging: a class and an interface of one name in one
// scope merge, and the interface's members are never checked for
// initialization. Each later declaration of the other kind is one report,
// labelled first on the declaration that introduced the name.
lint_check_declaration_merging :: proc(l: ^Linter, ctx: ^LintContext, body: []^Statement) {
	if !lint_is_typescript(ctx) || !lint_rule_enabled(l, .L3017_NoUnsafeDeclarationMerging) { return }
	first := make(map[string]LintMergeName, 8, context.temp_allocator)
	for stmt in body {
		entry, found := lint_merge_declaration(stmt)
		if !found { continue }
		earlier, seen := first[entry.name]
		if !seen { first[entry.name] = entry; continue }
		if earlier.class != entry.class { lint_emit(l, earlier.loc, .L3017_NoUnsafeDeclarationMerging) }
	}
}

// no-useless-empty-export: `export {}` only matters in a file with no other export.
lint_check_empty_export :: proc(l: ^Linter, body: []^Statement) {
	if !lint_rule_enabled(l, .L3018_NoUselessEmptyExport) { return }
	exports := false
	for stmt in body {
		if stmt == nil { continue }
		#partial switch node in stmt^ {
		case ^ExportDefaultDeclaration, ^ExportAllDeclaration:
			exports = true
		case ^ExportNamedDeclaration:
			if node.declaration != nil || len(node.specifiers) != 0 { exports = true }
		}
	}
	if !exports { return }
	for stmt in body {
		if stmt == nil { continue }
		node, is_export := stmt^.(^ExportNamedDeclaration)
		if !is_export || node.declaration != nil || len(node.specifiers) != 0 { continue }
		lint_emit(l, node.loc, .L3018_NoUselessEmptyExport)
	}
}

// The range of a literal type that restates its initializer, or false.
lint_as_const_literal :: proc(type: ^TSType, value: ^Expression) -> (Loc, bool) {
	if type == nil || value == nil { return {}, false }
	literal_type, is_literal := type^.(^TSLiteralType)
	if !is_literal || literal_type == nil || literal_type.literal == nil { return {}, false }
	#partial switch literal in literal_type.literal^ {
	case ^StringLiteral:
		initial, same_kind := value^.(^StringLiteral)
		if same_kind && initial.value == literal.value { return literal.loc, true }
	case ^NumericLiteral:
		initial, same_kind := value^.(^NumericLiteral)
		if same_kind && abs(initial.value - literal.value) < 2.220446049250313e-16 { return literal.loc, true }
	}
	return {}, false
}

lint_pattern_annotation :: proc(pattern: Pattern) -> Maybe(^TSTypeAnnotation) {
	#partial switch node in pattern {
	case ^Identifier:    return node.type_annotation
	case ^ObjectPattern: return node.type_annotation
	case ^ArrayPattern:  return node.type_annotation
	}
	return nil
}

lint_check_as_const_annotation :: proc(l: ^Linter, annotation: Maybe(^TSTypeAnnotation), value: Maybe(^Expression)) {
	wrapper, annotated := annotation.?
	init, has_init := value.?
	if !annotated || wrapper == nil || !has_init { return }
	if loc, restated := lint_as_const_literal(wrapper.type_annotation, init); restated {
		lint_emit(l, loc, .L3003_PreferAsConst)
	}
}

// prefer-as-const: `let x: 'a' = 'a'` and `'a' as 'a'` repeat the literal.
lint_check_as_const_declaration :: proc(l: ^Linter, ctx: ^LintContext, d: ^VariableDeclaration) {
	if !lint_is_typescript(ctx) || !lint_rule_enabled(l, .L3003_PreferAsConst) { return }
	for decl in d.declarations { lint_check_as_const_annotation(l, lint_pattern_annotation(decl.id), decl.init) }
}

lint_check_as_const_field :: proc(l: ^Linter, ctx: ^LintContext, elem: ClassElement) {
	if elem.kind != .Field || !lint_is_typescript(ctx) || !lint_rule_enabled(l, .L3003_PreferAsConst) { return }
	lint_check_as_const_annotation(l, elem.typing.annotation, elem.value)
}

lint_check_as_const_expression :: proc(l: ^Linter, e: ^TSAsExpression) {
	if !lint_rule_enabled(l, .L3003_PreferAsConst) { return }
	if loc, restated := lint_as_const_literal(e.type_annotation, e.expression); restated {
		lint_emit(l, loc, .L3003_PreferAsConst)
	}
}

LintReferenceOption :: enum u8 { Default, Always, Never, Prefer_Import }

// The first `types=`, `path=` or `lib=` attribute of a `/// <reference … />` comment.
lint_reference_attribute :: proc(comment: string) -> (key, value: string, ok: bool) {
	if !strings.has_prefix(comment, "/") { return "", "", false }
	open :: "<reference "
	start := strings.index(comment, open)
	if start < 0 { return "", "", false }
	end := strings.index(comment[start:], "/>")
	if end < 0 { return "", "", false }
	body := comment[start + len(open):start + end]
	for part in strings.fields(body, context.temp_allocator) {
		named := strings.has_prefix(part, "types=") || strings.has_prefix(part, "path=") || strings.has_prefix(part, "lib=")
		if !named { continue }
		pieces := strings.split(part, "=", context.temp_allocator)
		if len(pieces) != 2 { return "", "", false }
		key = strings.trim(strings.trim_space(pieces[0]), "\"")
		value = strings.trim_right(strings.trim(pieces[1], "\""), "/")
		return key, value, true
	}
	return "", "", false
}

// triple-slash-reference: `path` references are reported, `lib` ones are not,
// and a `types` reference only when the file also imports that module.
lint_check_triple_slash :: proc(l: ^Linter, ctx: ^LintContext, program: ^Program) {
	if !lint_is_typescript(ctx) || !lint_rule_enabled(l, .L3020_TripleSlashReference) { return }
	limit := u32(len(l.source))
	if len(program.body) > 0 && program.body[0] != nil { limit = get_statement_loc(program.body[0]).start }
	options := l.options.triple_slash
	pending := make(map[string]Loc, 4, context.temp_allocator)
	for comment in l.comments {
		if comment.start >= limit { break }
		key, value, found := lint_reference_attribute(comment.value)
		if !found { continue }
		loc := Loc{comment.start, comment.end}
		never := false
		switch key {
		case "types":
			never = options.types == .Never
			if options.types == .Default || options.types == .Prefer_Import { pending[value] = loc }
		case "path": never = options.path == .Default || options.path == .Never
		case "lib":  never = options.lib == .Never
		}
		if never { lint_emit(l, loc, .L3020_TripleSlashReference) }
	}
	if len(pending) == 0 { return }
	for stmt in program.body {
		if stmt == nil { continue }
		module := ""
		#partial switch node in stmt^ {
		case ^ImportDeclaration: module = node.source.value
		case ^TSImportEqualsDeclaration:
			if external, is_external := node.module_reference.(^TSExternalModuleReference); is_external && external.expression != nil {
				module = external.expression.value
			}
		case: continue
		}
		if loc, referenced := pending[module]; referenced { lint_emit(l, loc, .L3020_TripleSlashReference) }
	}
}
