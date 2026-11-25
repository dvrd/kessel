package kessel

import "core:fmt"
import "core:encoding/json"
import "core:mem"
import "core:slice"
import "core:strings"
import "core:text/regex"

// The normal lint walk records syntax that resolved references alone do not
// retain. All tables belong to this file's arena and only exist for this rule.
LintHookDependencies :: struct {
	calls: [dynamic]LintDependencyCall,
	bindings: map[u32]LintDependencyBinding,
	roots: map[u32]^MemberExpression,
	parents: map[^MemberExpression]^MemberExpression,
	callees: map[^MemberExpression]bool,
	cleanup_functions: map[u32]bool,
	current_writes: map[u32]bool,
	patterns: map[u32]^ObjectPattern,
	custom_hooks: ^LintCustomHooks,
	custom_names: map[string]bool,
}

LintCustomHooks :: struct { pattern: regex.Regular_Expression }
LintDependencyNote :: struct { start, end: u32, message: string }
LintDependencyNotes :: struct { message: string, uses: []LintDependencyNote }
LintDependencyCapture :: struct { span: Loc, reference: ^Ref }

lint_dependency_options :: proc(options: []json.Value, allocator: mem.Allocator) -> (^LintCustomHooks, bool) {
	if len(options) == 0 { return nil, true }
	if len(options) != 1 { return nil, false }
	object, ok := options[0].(json.Object)
	if !ok { return nil, false }
	if len(object) == 0 { return nil, true }
	source, valid := object["additionalHooks"].(json.String)
	if !valid || len(object) != 1 { return nil, false }
	if len(source) == 0 { return nil, true }
	pattern, err := regex.create(string(source), {.Unicode, .No_Capture}, allocator, context.temp_allocator)
	// Oxlint ignores a malformed custom pattern and keeps checking the built-in hooks.
	if err != nil { return nil, true }
	result := new(LintCustomHooks, allocator)
	result.pattern = pattern
	return result, true
}

LintDependencyCall :: struct { call: ^CallExpression, name: string, root: u32, callback_index: int }
LintDependencyBinding :: struct { body, initializer: Loc, async, stable, setter, unique, event: bool }
LintDependencyModel :: struct {
	syntax: ^LintHookDependencies,
	model: ^SemanticModel,
	ordered: []^Ref,
	references: map[u32]^Ref,
	functions: []ScopeId,
	stable: []bool,
	owned_refs: map[SymbolId]bool,
}

lint_dependencies_init :: proc(index: ^LintHookDependencies, alloc: mem.Allocator) {
	index.calls = make([dynamic]LintDependencyCall, alloc)
	index.bindings = make(map[u32]LintDependencyBinding, alloc)
	index.roots = make(map[u32]^MemberExpression, alloc)
	index.parents = make(map[^MemberExpression]^MemberExpression, alloc)
	index.callees = make(map[^MemberExpression]bool, alloc)
	index.cleanup_functions = make(map[u32]bool, alloc)
	index.current_writes = make(map[u32]bool, alloc)
	index.patterns = make(map[u32]^ObjectPattern, alloc)
	index.custom_names = make(map[string]bool, alloc)
}

lint_dependency_member :: proc(index: ^LintHookDependencies, member: ^MemberExpression) {
	if member.computed || member.property == nil { return }
	object := semantic_runtime_expression(member.object)
	if object == nil { return }
	#partial switch base in object^ {
	case ^Identifier: index.roots[base.loc.start] = member
	case ^MemberExpression: index.parents[base] = member
	}
}

lint_dependency_call :: proc(index: ^LintHookDependencies, call: ^CallExpression) {
	callee := semantic_runtime_expression(call.callee)
	if callee == nil { return }
	name: string
	root: u32
	#partial switch node in callee^ {
	case ^Identifier:
		name, root = node.name, node.loc.start
	case ^MemberExpression:
		index.callees[node] = true
		if node.computed || node.object == nil || node.property == nil { return }
		base, named := node.object^.(^Identifier)
		key, direct := node.property^.(^Identifier)
		if !named || !direct { return }
		name, root = key.name, base.loc.start
	case: return
	}
	callback_index := 0
	switch name {
	case "useEffect", "useLayoutEffect", "useCallback", "useMemo":
	case "useImperativeHandle": callback_index = 1
	case:
		if index.custom_hooks == nil { return }
		matches, cached := index.custom_names[name]
		if !cached {
			_, matches = regex.match_and_allocate_capture(index.custom_hooks.pattern, name, context.temp_allocator, context.temp_allocator)
			index.custom_names[name] = matches
		}
		if !matches { return }
	}
	append(&index.calls, LintDependencyCall{call, name, root, callback_index})
}

lint_dependency_initializer :: proc(expr: ^Expression) -> LintDependencyBinding {
	if expr == nil { return {} }
	#partial switch e in expr^ {
	case ^FunctionExpression:      return {body=e.loc, async=e.async, unique=true}
	case ^ArrowFunctionExpression: return {body=e.loc, async=e.async, unique=true}
	case ^ObjectExpression, ^ArrayExpression, ^ClassExpression, ^NewExpression, ^RegExpLiteral, ^JSXElement, ^JSXFragment:
		return {unique=true}
	case ^NullLiteral, ^NumericLiteral, ^BooleanLiteral, ^StringLiteral, ^BigIntLiteral: return {stable=true}
	}
	return {}
}

lint_dependency_binding :: proc(index: ^LintHookDependencies, decl: ^VariableDeclarator, kind: VariableKind) {
	init, present := decl.init.?
	if !present { return }
	expr := semantic_runtime_expression(init)
	if expr == nil { return }
	binding := lint_dependency_initializer(expr)
	binding.initializer = get_expression_loc(expr)
	#partial switch _ in expr^ {
	case ^AssignmentExpression, ^ConditionalExpression, ^LogicalExpression:
		binding.unique = lint_dependency_conditional_identity(expr)
	}
	if kind != .Const { binding.stable = false }
	hook: string
	if call, called := expr^.(^CallExpression); called {
		name, namespace := lint_hook_callee(call.callee)
		if namespace == "" || namespace == "React" { hook = name }
	}
	#partial switch pat in decl.id {
	case ^Identifier:
		if hook == "useRef" || hook == "useEffectEvent" { binding.stable = true }
		binding.event = hook == "useEffectEvent"
		index.bindings[pat.loc.start] = binding
	case ^ArrayPattern:
		switch hook {
		case "useState", "useReducer", "useTransition", "useActionState":
			if len(pat.elements) < 2 { return }
			if second, ok := pat.elements[1].?; ok {
				if id, named := second.(^Identifier); named {
					index.bindings[id.loc.start] = {stable=true, setter=hook == "useState" || hook == "useReducer"}
				}
			}
		}
	case ^ObjectPattern:
		if id := lint_dependency_identifier(expr); id != nil { index.patterns[id.loc.start] = pat }
	}
}

// Conditional initializers can allocate a fresh identity on either branch.
// Inspect only operands that supply the expression's value.
lint_dependency_conditional_identity :: proc(expr: ^Expression) -> bool {
	node := expr
	pending: [PARSE_RESOURCE_AST_DEPTH]^Expression = ---
	depth := 0
	for node != nil {
		if lint_dependency_initializer(node).unique { return true }
		left, right: ^Expression
		#partial switch e in node^ {
		case ^ConditionalExpression: left, right = e.consequent, e.alternate
		case ^LogicalExpression: left, right = e.left, e.right
		case ^AssignmentExpression: right = e.right
		}
		if left != nil {
			if depth == len(pending) { return false }
			pending[depth] = left
			depth += 1
		}
		if right == nil && depth > 0 { depth -= 1; right = pending[depth] }
		node = semantic_runtime_expression(right)
	}
	return false
}

// References need not arrive in source order (a computed key can be visited
// before its binding). Search a sorted view so each hook scans its own callback.
lint_dependency_range :: proc(refs: []^Ref, body: Loc) -> []^Ref {
	bounds: [2]int
	for offset, i in ([2]u32{body.start, body.end}) {
		low, high := 0, len(refs)
		for low < high {
			mid := low + (high-low)/2
			if refs[mid].start < offset { low = mid + 1 } else { high = mid }
		}
		bounds[i] = low
	}
	return refs[bounds[0]:bounds[1]]
}

lint_check_hook_dependencies :: proc(l: ^Linter, model: ^SemanticModel, syntax: ^LintHookDependencies) {
	alloc := l.allocator
	index := LintDependencyModel{
		syntax=syntax, model=model, ordered=make([]^Ref, len(model.refs), alloc),
		references=make(map[u32]^Ref, alloc), functions=make([]ScopeId, len(model.scopes), alloc),
		stable=make([]bool, len(model.symbols), alloc), owned_refs=make(map[SymbolId]bool, alloc),
	}
	for scope, i in model.scopes {
		assert(int(scope.parent) <= i)
		index.functions[i] = ScopeId(i) if scope.kind == .Function else index.functions[scope.parent]
	}
	for &ref, i in model.refs {
		index.ordered[i] = &ref
		if ref.kind != .Type {
			index.references[ref.start] = &ref
			if syntax.current_writes[ref.start] { index.owned_refs[ref.resolved] = true }
		}
	}
	slice.sort_by(index.ordered, proc(a, b: ^Ref) -> bool { return a.start < b.start })
	lint_dependency_stability(&index)
	for &site in syntax.calls {
		owner := index.references[site.root]
		if owner == nil { continue }
		render := index.functions[owner.scope]
		if render != SCOPE_ROOT { lint_dependency_check_call(l, &index, &site, render) }
	}
}

// A callback that captures only stable values is itself stable. Follow reverse
// capture edges from reactive bindings so aliases, cycles and forward references
// do not depend on declaration order.
lint_dependency_stability :: proc(index: ^LintDependencyModel) {
	model := index.model
	alloc := model.alloc
	users := make(map[SymbolId][dynamic]SymbolId, alloc)
	pending := make([dynamic]SymbolId, alloc)
	for &symbol, i in model.symbols {
		id := SymbolId(i)
		if id == SYMBOL_UNRESOLVED { continue }
		binding := index.syntax.bindings[symbol.decl_start]
		index.stable[id] = binding.stable || binding.body.end != 0
		if binding.body.end == 0 { continue }
		render := index.functions[symbol.scope]
		if render == SCOPE_ROOT { continue }
		for ref in lint_dependency_range(index.ordered, binding.body) {
			used := ref.resolved
			if ref.kind == .Type || used == SYMBOL_UNRESOLVED { continue }
			if used == id {
				if binding.initializer.end != 0 { index.stable[id] = false }
				continue
			}
			if index.functions[model.symbols[used].scope] != render { continue }
			if _, exists := users[used]; !exists { users[used] = make([dynamic]SymbolId, alloc) }
			append(&users[used], id)
		}
	}
	for ref in model.refs {
		if ref.kind == .Write || ref.kind == .ReadWrite { index.stable[ref.resolved] = false }
	}
	for id in users { if !index.stable[id] { append(&pending, id) } }
	for i := 0; i < len(pending); i += 1 {
		for dependent in users[pending[i]] {
			if index.stable[dependent] {
				index.stable[dependent] = false
				append(&pending, dependent)
			}
		}
	}
}

lint_dependency_path :: proc(index: ^LintDependencyModel, ref: ^Ref, read: bool) -> (string, Loc) {
	loc := Loc{ref.start, ref.end}
	parent := index.syntax.roots[ref.start]
	if parent == nil || (read && index.syntax.callees[parent]) { return ref.name, loc }
	builder := strings.builder_make(0, len(ref.name) + 24, index.model.alloc)
	strings.write_string(&builder, ref.name)
	for parent != nil {
		if read && index.syntax.callees[parent] { break }
		key, named := parent.property^.(^Identifier)
		if !named { break }
		next := index.syntax.parents[parent]
		if read && key.name == "current" && (next == nil || index.syntax.callees[next]) { break }
		strings.write_byte(&builder, '.')
		strings.write_string(&builder, key.name)
		if next != nil { loc = parent.loc }
		parent = next
	}
	return strings.to_string(builder), loc
}

lint_dependency_identifier :: proc(expr: ^Expression) -> ^Identifier {
	for value := semantic_runtime_expression(expr); value != nil; {
		#partial switch e in value^ {
		case ^Identifier: return e
		case ^MemberExpression:
			if e.computed { return nil }
			value = semantic_runtime_expression(e.object)
		case: return nil
		}
	}
	return nil
}

lint_dependency_covered :: proc(paths: map[string]$T, full: string) -> bool {
	for name := full; name != ""; {
		if _, present := paths[name]; present { return true }
		dot := strings.last_index_byte(name, '.')
		if dot < 0 { break }
		name = name[:dot]
	}
	return false
}

lint_dependency_report :: proc(l: ^Linter, loc: Loc, message: string) {
	lint_report(l, loc.start, loc.end, .L4108_ExhaustiveDeps, message)
}

lint_dependency_missing :: proc(l: ^Linter, index: ^LintDependencyModel, hook: string, array: Loc, missing: map[string]LintDependencyCapture, declared: map[string]Loc, literal: ^ArrayExpression) {
	if len(missing) == 0 { return }
	names := make([dynamic]string, 0, len(missing), l.allocator)
	for name in missing { append(&names, name) }
	slice.sort(names[:])
	builder := strings.builder_make(l.allocator)
	uses := make([]LintDependencyNote, len(names), l.allocator)
	mutable: string
	for name, i in names {
		span := missing[name].span
		uses[i] = {span.start, span.end, fmt.tprintf("%s uses `%s` here", hook, name)}
		field := fmt.tprintf("%s.current", name)
		if _, found := declared[field]; found && mutable == "" { mutable = field }
		if i > 0 {
			strings.write_string(&builder, ", ")
			if i + 1 == len(names) { strings.write_string(&builder, "and ") }
		}
		strings.write_byte(&builder, '\'')
		strings.write_string(&builder, name)
		strings.write_byte(&builder, '\'')
	}
	phrase := "a missing dependency" if len(names) == 1 else "missing dependencies"
	message := fmt.tprintf("React Hook %s has %s: %s", hook, phrase, strings.to_string(builder))
	if mutable != "" {
		message = fmt.tprintf("%s. Mutable values like '%s' aren't valid dependencies because mutating them doesn't re-render the component.", message, mutable)
	}
	if l.dependency_notes == nil { l.dependency_notes = make(map[Loc]LintDependencyNotes, l.allocator) }
	l.dependency_notes[array] = {message, uses}
	lint_dependency_report(l, array, message)
	if literal != nil && lint_dependency_wants_edit(l) {
		lint_dependency_fix_missing(l, index, literal, missing, message)
	}
}

lint_dependency_check_call :: proc(l: ^Linter, index: ^LintDependencyModel, site: ^LintDependencyCall, render: ScopeId) {
	call := site.call
	hook := site.name
	is_effect := strings.contains(hook, "Effect")
	if len(call.arguments) <= site.callback_index {
		lint_dependency_report(l, call.loc, fmt.tprintf("React hook %s requires an effect callback.", hook))
		return
	}
	callback := semantic_runtime_expression(call.arguments[site.callback_index])
	if callback == nil { return }
	variable, named := callback^.(^Identifier)
	deps: ^Expression
	if site.callback_index + 1 < len(call.arguments) { deps = semantic_runtime_expression(call.arguments[site.callback_index + 1]) }
	if deps == nil && !is_effect {
		if hook == "useMemo" || hook == "useCallback" {
			message := fmt.tprintf("React Hook %s does nothing when called with only one argument.", hook)
			lint_dependency_report(l, call.loc, message)
			if lint_dependency_wants_edit(l) {
				body := lint_dependency_initializer(callback).body
				if body.end != 0 { lint_dependency_fix_omitted(l, index, call, render, body, message) }
			}
		}
		return
	}
	binding := lint_dependency_initializer(callback)
	if named {
		if deps == nil { return }
		ref := index.references[variable.loc.start]
		if ref == nil || ref.resolved == SYMBOL_UNRESOLVED { return }
		array, literal := deps^.(^ArrayExpression)
		if literal {
			for element in array.elements {
				if value, present := element.?; present {
					node := semantic_runtime_expression(value)
					if node != nil { if id, ok := node^.(^Identifier); ok && id.name == variable.name { return } }
				}
			}
		}
		symbol := &index.model.symbols[ref.resolved]
		binding = index.syntax.bindings[symbol.decl_start]
		if binding.body.end == 0 {
			if symbol.kind != .Import {
				missing := make(map[string]LintDependencyCapture, l.allocator)
				missing[variable.name] = {variable.loc, ref}
				lint_dependency_missing(l, index, hook, get_expression_loc(deps), missing, nil, array)
			}
			return
		}
	} else if binding.body.end == 0 {
		lint_dependency_report(l, get_expression_loc(call.callee), fmt.tprintf("React Hook %s received a function whose dependencies are unknown.", hook))
		return
	}
	if is_effect && binding.async { lint_dependency_report(l, binding.body, "Effect callbacks are synchronous to prevent race conditions.") }
	if is_effect { lint_dependency_check_cleanup(l, index, render, binding.body) }
	if deps != nil {
		if array, ok := deps^.(^ArrayExpression); ok {
			lint_dependency_check_array(l, index, site, render, binding.body, array, is_effect)
			return
		}
		id, is_identifier := deps^.(^Identifier)
		ref := index.references[get_expression_loc(deps).start]
		if !is_identifier || id.name != "undefined" || (ref != nil && ref.resolved != SYMBOL_UNRESOLVED) {
			lint_dependency_report(l, get_expression_loc(deps), fmt.tprintf("React Hook %s was passed a dependency list that is not an array literal.", hook))
		}
	}
	if is_effect { lint_dependency_check_setter(l, index, site, binding.body) }
}

lint_dependency_check_setter :: proc(l: ^Linter, index: ^LintDependencyModel, site: ^LintDependencyCall, body: Loc) {
	for ref in lint_dependency_range(index.ordered, body) {
		if ref.kind == .Type || ref.resolved == SYMBOL_UNRESOLVED { continue }
		scope := index.model.scopes[index.functions[ref.scope]]
		if scope.node_start != body.start || scope.node_end != body.end { continue }
		symbol := &index.model.symbols[ref.resolved]
		if !index.syntax.bindings[symbol.decl_start].setter { continue }
		lint_dependency_report(l, get_expression_loc(site.call.callee), fmt.tprintf("React Hook %s calls a state setter without a dependency array. This can cause repeated renders.", site.name))
		return
	}
}

lint_dependency_declared :: proc(l: ^Linter, index: ^LintDependencyModel, hook: string, render: ScopeId, array: ^ArrayExpression) -> map[string]Loc {
	declared := make(map[string]Loc, l.allocator)
	for element, i in array.elements {
		value, present := element.?
		if !present { continue }
		node := semantic_runtime_expression(value)
		if node == nil { continue }
		loc := get_expression_loc(node)
		id := lint_dependency_identifier(node)
		if id == nil {
			#partial switch _ in node^ {
			case ^NullLiteral, ^NumericLiteral, ^BooleanLiteral, ^StringLiteral, ^BigIntLiteral, ^RegExpLiteral:
				lint_dependency_report(l, loc, "The literal is not a valid dependency because it never changes.")
			case ^JSXElement:
			case: lint_dependency_report(l, loc, fmt.tprintf("React Hook %s has a complex expression in the dependency array.", hook))
			}
			continue
		}
		ref := index.references[id.loc.start]
		if ref == nil { continue }
		path, _ := lint_dependency_path(index, ref, false)
		if _, exists := declared[path]; exists {
			lint_dependency_report_removable(l, loc, array, i, "This dependency is specified more than once in the dependency array.")
			continue
		}
		declared[path] = loc
		if ref.resolved == SYMBOL_UNRESOLVED || index.functions[index.model.symbols[ref.resolved].scope] != render ||
		   (strings.has_suffix(path, ".current") && index.stable[ref.resolved]) {
			lint_dependency_report_removable(l, loc, array, i, fmt.tprintf("React Hook %s has an unnecessary dependency: %s.", hook, ref.name))
		}
		if ref.resolved == SYMBOL_UNRESOLVED { continue }
		binding := index.syntax.bindings[index.model.symbols[ref.resolved].decl_start]
		if binding.event { lint_dependency_report(l, loc, "Functions returned from useEffectEvent must be omitted from dependency arrays.") }
		if path == ref.name && binding.unique {
			lint_dependency_report(l, loc, fmt.tprintf("React hook %s depends on `%s`, which changes every render", hook, path))
		}
	}
	return declared
}

lint_dependency_return :: proc(index: ^LintHookDependencies, value: ^Expression) {
	binding := lint_dependency_initializer(semantic_runtime_expression(value))
	if binding.body.end != 0 { index.cleanup_functions[binding.body.start] = true }
}

lint_dependency_current :: proc(member: ^MemberExpression) -> ^Identifier {
	if member == nil || member.computed || member.property == nil { return nil }
	key, named := member.property^.(^Identifier)
	if !named || key.name != "current" { return nil }
	object := semantic_runtime_expression(member.object)
	if object == nil { return nil }
	id, _ := object^.(^Identifier)
	return id
}

lint_dependency_record_write :: proc(index: ^LintHookDependencies, target: ^Expression) {
	value := semantic_runtime_expression(target)
	if value == nil { return }
	if member, ok := value^.(^MemberExpression); ok {
		if id := lint_dependency_current(member); id != nil { index.current_writes[id.loc.start] = true }
	}
}

lint_dependency_check_cleanup :: proc(l: ^Linter, index: ^LintDependencyModel, render: ScopeId, body: Loc) {
	if len(index.syntax.cleanup_functions) == 0 { return }
	for ref in lint_dependency_range(index.ordered, body) {
		member := index.syntax.roots[ref.start]
		if lint_dependency_current(member) == nil { continue }
		if ref.resolved != SYMBOL_UNRESOLVED {
			if index.owned_refs[ref.resolved] || index.functions[index.model.symbols[ref.resolved].scope] != render { continue }
		}
		for scope := index.functions[ref.scope]; scope != SCOPE_ROOT; {
			current := &index.model.scopes[scope]
			if current.node_start <= body.start || current.node_end > body.end { break }
			parent := index.functions[current.parent]
			if index.syntax.cleanup_functions[current.node_start] && index.model.scopes[parent].node_start == body.start {
				lint_dependency_report(l, member.loc, "The ref's value `.current` is accessed directly in the effect cleanup function.")
				break
			}
			scope = parent
		}
	}
}

LintDependencyUses :: struct {
	declared: map[string]Loc,
	missing: map[string]LintDependencyCapture,
	used: map[string]bool,
}

lint_dependency_use :: proc(uses: ^LintDependencyUses, path: string, capture: LintDependencyCapture, reactive: bool) {
	for ancestor := path; ancestor != ""; {
		uses.used[ancestor] = true
		dot := strings.last_index_byte(ancestor, '.')
		if dot < 0 { break }
		ancestor = ancestor[:dot]
	}
	if reactive && !lint_dependency_covered(uses.declared, path) {
		if _, seen := uses.missing[path]; !seen { uses.missing[path] = capture }
	}
}

// A static destructuring read depends on its property keys. Rest or computed
// properties need the whole receiver because the selected keys vary at runtime.
lint_dependency_pattern :: proc(uses: ^LintDependencyUses, pat: ^ObjectPattern, path: string, capture: LintDependencyCapture, reactive: bool) -> bool {
	if pat == nil || len(pat.properties) == 0 { return false }
	for prop in pat.properties {
		if prop.computed { return false }
		key, ok := prop.key.?
		if !ok { return false }
		if _, named := key.(IdentifierName); !named { return false }
	}
	for prop in pat.properties {
		key := prop.key.(ObjectPatternPropertyKey).(IdentifierName)
		if key.name == "current" { lint_dependency_use(uses, path, capture, reactive); continue }
		lint_dependency_use(uses, fmt.tprintf("%s.%s", path, key.name), capture, reactive)
	}
	return true
}

lint_dependency_collect :: proc(l: ^Linter, index: ^LintDependencyModel, render: ScopeId, callback: Loc, declared: map[string]Loc) -> LintDependencyUses {
	uses := LintDependencyUses{
		declared=declared,
		missing=make(map[string]LintDependencyCapture, l.allocator), used=make(map[string]bool, l.allocator),
	}
	for ref in lint_dependency_range(index.ordered, callback) {
		if ref.kind == .Type { continue }
		symbol := &index.model.symbols[ref.resolved]
		if ref.resolved != SYMBOL_UNRESOLVED && callback.start <= symbol.decl_start && symbol.decl_start < callback.end { continue }
		reactive := ref.resolved != SYMBOL_UNRESOLVED && !index.stable[ref.resolved] && index.functions[symbol.scope] == render
		if reactive {
			initializer := index.syntax.bindings[symbol.decl_start].initializer
			if initializer.start <= ref.start && ref.end <= initializer.end { reactive = false }
		}
		path, loc := lint_dependency_path(index, ref, true)
		pattern := index.syntax.patterns[ref.start]
		if lint_dependency_pattern(&uses, pattern, path, {loc, ref}, reactive) { continue }
		lint_dependency_use(&uses, path, {loc, ref}, reactive)
		if lint_dependency_current(index.syntax.roots[ref.start]) != nil {
			uses.used[fmt.tprintf("%s.current", ref.name)] = true
		}
	}
	return uses
}

lint_dependency_check_array :: proc(l: ^Linter, index: ^LintDependencyModel, site: ^LintDependencyCall, render: ScopeId, callback: Loc, array: ^ArrayExpression, is_effect: bool) {
	declared := lint_dependency_declared(l, index, site.name, render, array)
	uses := lint_dependency_collect(l, index, render, callback, declared)
	lint_dependency_missing(l, index, site.name, array.loc, uses.missing, uses.declared, array)
	if !is_effect {
		for element, i in array.elements {
			value, present := element.?
			if !present { continue }
			id := lint_dependency_identifier(value)
			if id == nil { continue }
			ref := index.references[id.loc.start]
			if ref == nil { continue }
			path, _ := lint_dependency_path(index, ref, false)
			if uses.declared[path] != get_expression_loc(semantic_runtime_expression(value)) { continue }
			dot := strings.last_index_byte(path, '.')
			redundant := dot >= 0 && lint_dependency_covered(uses.declared, path[:dot])
			if redundant || !uses.used[path] {
				lint_dependency_report_removable(l, array.loc, array, i, fmt.tprintf("React Hook %s has unnecessary dependency: %s", site.name, path))
			}
		}
	}
}
