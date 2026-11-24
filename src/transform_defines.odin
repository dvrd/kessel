package kessel

import "core:mem"
import mvirtual "core:mem/virtual"
import "core:slice"
import "core:strings"

// Match paths from the property back to the root. Most references can be
// discarded by their last name without walking the rest of the expression.
TransformDefineRule :: struct {
	parts: []string,
	value, grouped: string,
	assignable, member_target, typeof_operand: bool,
}

TransformDefineUse :: struct {
	loc: Loc,
	scope: ScopeId,
	root, prefix, value: string,
}

TransformDefines :: struct {
	rules: map[string][dynamic]TransformDefineRule,
	uses: [dynamic]TransformDefineUse,
	shorthand: map[u32]bool,
	eval_scopes: map[ScopeId]bool,
	local_this_depth, with_depth: int,
}

transform_define_prepare :: proc(state: ^TransformDefines, values: map[string]string, minified: bool, alloc: mem.Allocator) -> Maybe(StripDiagnostic) {
	context.allocator = alloc
	state.rules = make(map[string][dynamic]TransformDefineRule, alloc)
	state.uses = make([dynamic]TransformDefineUse, alloc)
	state.shorthand = make(map[u32]bool, alloc)
	state.eval_scopes = make(map[ScopeId]bool, alloc)
	for name, expression in values {
		path := strings.trim_prefix(name, "typeof ")
		wildcard := strings.has_suffix(path, ".*")
		if wildcard && !strings.has_prefix(path, "import.meta.") {
			return StripDiagnostic{what = "define wildcard requires an import.meta path"}
		}
		if !jsx_pragma_valid(strings.trim_suffix(path, ".*")) {
			return StripDiagnostic{what = strings.concatenate({"invalid define name: ", name}, alloc)}
		}
		parts := strings.split(path, ".", alloc)
		rule := TransformDefineRule{parts = parts, typeof_operand = path != name}
		if !transform_define_value(&rule, expression, minified, alloc) {
			return StripDiagnostic{what = strings.concatenate({"expected a JavaScript expression for define ", name}, alloc)}
		}
		last := parts[len(parts)-1]
		bucket := state.rules[last]
		append(&bucket, rule)
		state.rules[last] = bucket
	}
	return nil
}

transform_define_value :: proc(rule: ^TransformDefineRule, text: string, minified: bool, alloc: mem.Allocator) -> bool {
	// Grouping accepts object literals and sequence expressions. Checking the
	// exact extent rejects a value that closes the wrapper and adds statements.
	wrapped := strings.concatenate({"(", text, "\n);"}, alloc)
	job: ParseJob
	if !parse_job_open_inline(&job, wrapped, {preserve_parens = true}, "define.mjs") { return false }
	defer parse_job_close(&job)
	parse_job_run(&job)
	if len(job.parser.errors) != 0 || len(job.program.body) != 1 { return false }
	stmt, ok := job.program.body[0]^.(^ExpressionStatement)
	if !ok || stmt.expression == nil { return false }
	group, grouped := stmt.expression^.(^ParenthesizedExpression)
	if !grouped || group.loc.start != 0 || int(group.loc.end) != len(wrapped)-1 { return false }
	context.allocator = job.arena_alloc
	cg: Codegen
	codegen_init(&cg, {minified = minified, indent = "  "}, wrapped, context.allocator)
	defer codegen_destroy(&cg, context.allocator)
	value := group.expression
	for {
		inner, ok := value^.(^ParenthesizedExpression)
		if !ok { break }
		value = inner.expression
	}
	gen_expression(&cg, value)
	rule.value = strings.clone(string(cg.buf[:cg.pos]), alloc)
	rule.grouped = strings.concatenate({"(", rule.value, ")"}, alloc)
	#partial switch v in value^ {
	case ^Identifier: rule.assignable = v.name != "eval" && v.name != "arguments"
	case ^MemberExpression:
		rule.assignable = !v.optional
		rule.member_target = rule.assignable
	}
	return true
}

transform_define_property :: proc(member: ^MemberExpression) -> (string, bool) {
	if member.property == nil { return "", false }
	#partial switch property in member.property^ {
	case ^Identifier: return property.name, !member.computed
	case ^StringLiteral: return property.value, member.computed
	case ^TemplateLiteral:
		if len(property.expressions) == 0 && len(property.quasis) == 1 {
			if cooked, ok := property.quasis[0].cooked.?; ok { return cooked, member.computed }
		}
	}
	return "", false
}

transform_define_matches :: proc(expr: ^Expression, parts: []string, local_this: bool) -> (string, bool) {
	node := expr
	for i := len(parts)-1; i >= 0 && node != nil; i -= 1 {
		#partial switch v in node^ {
		case ^Identifier: return v.name, i == 0 && parts[0] == v.name
		case ^ThisExpression: return "", i == 0 && parts[0] == "this" && !local_this
		case ^MetaProperty: return "", i == 1 && parts[0] == "import" && parts[1] == "meta" && v.meta.name == "import"
		case ^MemberExpression:
			key, ok := transform_define_property(v)
			if !ok || (parts[i] != "*" && parts[i] != key) { return "", false }
			node = semantic_runtime_expression(v.object)
		case: return "", false
		}
	}
	return "", false
}

transform_define_note :: proc(ctx: ^SemCtx, expr: ^Expression, write: bool, deleting := false) {
	state := ctx.defines
	node := expr
	unary, typeof_operand := expr^.(^UnaryExpression)
	if typeof_operand {
		if unary.operator != .Typeof { return }
		node = semantic_runtime_expression(unary.argument)
	}
	if node == nil { return }
	last: string
	member := false
	#partial switch v in node^ {
	case ^Identifier: last = v.name
	case ^ThisExpression: last = "this"
	case ^MetaProperty: last = v.property.name
	case ^MemberExpression:
		last, member = transform_define_property(v)
		if !member { return }
	case ^CallExpression:
		callee := semantic_runtime_expression(v.callee)
		if !v.optional && callee != nil && !ctx.model.scopes[ctx.cur_scope].strict {
			if id, ok := callee^.(^Identifier); ok && id.name == "eval" {
				scope := ctx.cur_scope
				for !semantic_is_function_scope(ctx.model, scope) { scope = ctx.model.scopes[scope].parent }
				state.eval_scopes[scope] = true
			}
		}
		return
	case: return
	}
	if state.with_depth != 0 { return }
	// An exact property takes precedence over an import.meta wildcard.
	buckets := [2]string{last, "*"}
	for bucket, index in buckets {
		if index == 1 && !member { break }
		for rule in state.rules[bucket] {
			if rule.typeof_operand != typeof_operand { continue }
			root, ok := transform_define_matches(node, rule.parts, state.local_this_depth > 0)
			if !ok { continue }
			if write && !rule.assignable { return }
			if deleting && !rule.member_target { return }
			value := rule.value if write else rule.grouped
			append(&state.uses, TransformDefineUse{get_expression_loc(expr), ctx.cur_scope, root, "", value})
			return
		}
	}
}

transform_define_global :: proc(model: ^SemanticModel, state: ^TransformDefines, use: TransformDefineUse) -> bool {
	if use.root == "" { return true }
	if use.root == "arguments" && model.scopes[use.scope].implicit_arguments { return false }
	if semantic_lookup(model, use.scope, use.root) != SYMBOL_UNRESOLVED { return false }
	if len(state.eval_scopes) != 0 {
		scope := use.scope
		for {
			if state.eval_scopes[scope] { return false }
			if scope == SCOPE_ROOT { break }
			scope = model.scopes[scope].parent
		}
	}
	return true
}

transform_define_apply :: proc(job: ^ParseJob, cg: ^Codegen, values: map[string]string) -> Maybe(StripDiagnostic) {
	if len(values) == 0 { return nil }
	scratch: mvirtual.Arena
	if mvirtual.arena_init_growing(&scratch) != nil { return StripDiagnostic{what = "cannot allocate transform definitions"} }
	defer mvirtual.arena_destroy(&scratch)
	state: TransformDefines
	if diag, failed := transform_define_prepare(&state, values, cg.cfg.minified, mvirtual.arena_allocator(&scratch)).?; failed {
		return StripDiagnostic{diag.loc, strings.clone(diag.what, job.arena_alloc)}
	}
	if job.source_is_dts { return nil }
	return transform_define_rewrite(job, cg, &state)
}

transform_define_rewrite :: proc(job: ^ParseJob, cg: ^Codegen, state: ^TransformDefines) -> Maybe(StripDiagnostic) {
	// Work on the emitted JavaScript so erased bindings and synthesized JSX
	// calls have the same scope and spelling the runtime will see.
	source := string(cg.buf[:cg.pos])
	output: ParseJob
	lang: Lang = .JSX if job.lang == .JSX || job.lang == .TSX else .JS
	source_type: SourceType = .Script if cg.cfg.strip_module == .Script else .Module
	config := ParseConfig{lang_override = lang, source_type_override = source_type, preserve_parens = true,
		is_commonjs_override = job.is_commonjs}
	if !parse_job_open_inline(&output, source, config, "define.js") { return StripDiagnostic{what = "cannot open transformed JavaScript"} }
	defer parse_job_close(&output)
	parse_job_run(&output)
	if len(output.parser.errors) != 0 { return StripDiagnostic{what = "cannot apply defines to invalid transformed JavaScript"} }
	model := semantic_build(output.program, source, lang, output.arena_alloc, defines = state)
	slice.sort_by(state.uses[:], proc(a, b: TransformDefineUse) -> bool {
		if a.loc.start == b.loc.start { return b.loc.end < a.loc.end }
		return a.loc.start < b.loc.start
	})
	end: u32
	count := 0
	for &use in state.uses {
		if use.loc.start < end || !transform_define_global(&model, state, use) { continue }
		if state.shorthand[use.loc.start] {
			key := source[use.loc.start:use.loc.end]
			if use.root == "__proto__" { key = "[\"__proto__\"]" }
			use.prefix = strings.concatenate({key, ": "}, output.arena_alloc)
		}
		state.uses[count] = use
		count += 1
		end = use.loc.end
	}
	if count == 0 { return nil }
	edits := state.uses[:count]
	total := len(source)
	for edit in edits { total += len(edit.prefix) + len(edit.value) - int(edit.loc.end - edit.loc.start) }
	if total > int(max(i32)) { return StripDiagnostic{what = "transformed JavaScript exceeds the supported output size"} }
	// Allocate once at the final size. Replacement text can greatly exceed
	// the input-sized parse arena when a long value is used many times.
	buffer := make([]byte, total, context.allocator)
	position := 0
	end = 0
	for edit in edits {
		position += copy(buffer[position:], transmute([]byte)source[end:edit.loc.start])
		position += copy(buffer[position:], transmute([]byte)edit.prefix)
		position += copy(buffer[position:], transmute([]byte)edit.value)
		end = edit.loc.end
	}
	position += copy(buffer[position:], transmute([]byte)source[end:])
	assert(position == total)
	if cg.sm != nil { transform_define_remap(cg.sm, edits) }
	delete(cg.buf, context.allocator)
	cg.buf, cg.pos = buffer, total
	parse_job_close(&output)
	return transform_define_validate(job, string(buffer), config)
}

// Expressions such as await calls and import.meta have different legal
// positions in scripts, modules, and functions. Check the actual placements.
transform_define_validate :: proc(job: ^ParseJob, source: string, config: ParseConfig) -> Maybe(StripDiagnostic) {
	check: ParseJob
	if !parse_job_open_inline(&check, source, config, "define.js") { return StripDiagnostic{what = "cannot verify transformed JavaScript"} }
	defer parse_job_close(&check)
	parse_job_run(&check)
	if len(check.parser.errors) != 0 {
		message := strings.concatenate({"invalid define replacement in this context: ", check.parser.errors[0].message}, job.arena_alloc)
		return StripDiagnostic{what = message}
	}
	return nil
}

transform_define_remap :: proc(sm: ^SourceMap, edits: []TransformDefineUse) {
	slice.sort_by(sm.records[:], proc(a, b: SourceMapRecord) -> bool { return a.gen_offset < b.gen_offset })
	index, delta, written := 0, 0, 0
	for &record in sm.records {
		for index < len(edits) && edits[index].loc.end <= record.gen_offset {
			edit := edits[index]
			delta += len(edit.prefix) + len(edit.value) - int(edit.loc.end - edit.loc.start)
			index += 1
		}
		if index < len(edits) && edits[index].loc.start < record.gen_offset { continue }
		record.gen_offset = u32(int(record.gen_offset) + delta)
		sm.records[written] = record
		written += 1
	}
	resize(&sm.records, written)
}
