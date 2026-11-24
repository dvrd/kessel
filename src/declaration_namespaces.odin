package kessel

DeclarationRegion :: struct {
	body: []^Statement,
	bindings: map[string][dynamic]int,
	first, end, parent, depth, symbol: int,
	active, ambient, marker, private_items: bool,
	scan: DeclarationRegionScan,
}

DeclarationNamespaceKey :: struct { parent: int, name: string }
DeclarationBindingSpace :: enum { Either, Value, Type }

// Namespace blocks have private lexical bindings and share exported members
// with other declarations of the same namespace. Index before resolving so a
// signature can use a type declared in a later block.
@(private)
dts_index_regions :: proc(state: ^DeclarationEmit) {
	state.namespaces = make(map[DeclarationNamespaceKey]int)
	state.exports = make(map[DeclarationNamespaceKey][dynamic]int)
	append(&state.regions, DeclarationRegion{body = state.job.program.body[:], parent = -1, active = true})
	for cursor := 0; cursor < len(state.regions); cursor += 1 {
		state.region = cursor
		state.regions[cursor].bindings = make(map[string][dynamic]int)
		state.regions[cursor].first = len(state.items)
		for stmt, group in state.regions[cursor].body { dts_index(state, stmt^, group) }
		state.regions[cursor].end = len(state.items)
		for index := state.regions[cursor].first; index < state.regions[cursor].end; index += 1 {
			item := &state.items[index]
			if ns, ok := item.statement.(^TSModuleDeclaration); ok { dts_namespace_region(state, item, ns) }
		}
	}
	dts_index_export_targets(state)
	state.region = 0
}

// Export aliases bind their targets even in a namespace that will be elided.
// Mark targets in their own block. A private enclosing namespace stays private.
@(private)
dts_index_export_targets :: proc(state: ^DeclarationEmit) {
	pending: [dynamic]int
	for item in state.items {
		if item.region == 0 { continue }
		state.region = item.region
		#partial switch s in item.statement {
		case ^ExportNamedDeclaration:
			if s.source != nil { continue }
			for spec in s.specifiers {
				name := convert_export_spec_name(spec.local).name
				append(&pending, ..dts_lookup(state, name, .Either))
			}
		case ^ExportDefaultDeclaration:
			if expr, expression := s.declaration^.(^Expression); expression {
				if id, simple := expr^.(^Identifier); simple { append(&pending, ..dts_lookup(state, id.name, .Either)) }
			}
		}
	}
	seen := make(map[int]bool)
	for len(pending) > 0 {
		index := pop(&pending)
		if seen[index] { continue }
		seen[index] = true
		item := &state.items[index]
		item.root = true
		if item.region == 0 { dts_select(state, index) }
		alias, imported := item.statement.(^TSImportEqualsDeclaration)
		if !imported { continue }
		expr, internal := alias.module_reference.(^Expression)
		if !internal { continue }
		state.region = item.region
		for expr != nil {
			#partial switch e in expr^ {
			case ^MemberExpression: expr = e.object; continue
			case ^Identifier: append(&pending, ..dts_lookup(state, e.name, .Either))
			}
			break
		}
	}
}

@(private)
dts_namespace_region :: proc(state: ^DeclarationEmit, item: ^DeclarationItem, ns: ^TSModuleDeclaration) {
	parent := &state.regions[item.region]
	symbol := parent.symbol
	// Unexported namespaces belong to this lexical block alone.
	if item.region != 0 && item.visibility == .Local && !parent.ambient { symbol = -item.region }
	node := ns
	for {
		key := DeclarationNamespaceKey{symbol, dts_member_name(node.id)}
		found: bool
		symbol, found = state.namespaces[key]
		if !found {
			symbol = len(state.namespaces) + 1
			state.namespaces[key] = symbol
		}
		body, ok := node.body.?
		if !ok { return }
		switch b in body^ {
		case ^TSModuleDeclaration: node = b
		case ^TSModuleBlock:
			item.child = len(state.regions)
			append(&state.regions, DeclarationRegion{
				body = b.body[:], parent = item.region, depth = parent.depth + 1, symbol = symbol,
				ambient = parent.ambient || ns.declare || ns.global,
			})
			return
		}
	}
}

@(private)
dts_namespace_header :: proc(state: ^DeclarationEmit, ns: ^TSModuleDeclaration) {
	cg := &state.writer
	if ns.global { cg_str(cg, "global"); return }
	_, external := ns.id^.(^StringLiteral)
	cg_str(cg, "module " if external else "namespace ")
	node := ns
	for {
		gen_expression(cg, node.id, PREC_CALL)
		body, has_body := node.body.?
		if !has_body { return }
		nested, dotted := body^.(^TSModuleDeclaration)
		if !dotted { return }
		cg_byte(cg, '.')
		node = nested
	}
}

@(private)
dts_lookup :: proc(state: ^DeclarationEmit, name: string, space: DeclarationBindingSpace) -> []int {
	for region := state.region; region >= 0; region = state.regions[region].parent {
		local := dts_binding_candidates(state, state.regions[region].bindings[name][:], space)
		if len(local) != 0 { return local }
		if region == 0 { break }
		shared := dts_binding_candidates(state, state.exports[{state.regions[region].symbol, name}][:], space)
		if len(shared) != 0 { return shared }
	}
	return nil
}

@(private)
dts_binding_candidates :: proc(state: ^DeclarationEmit, candidates: []int, space: DeclarationBindingSpace) -> []int {
	if space == .Either { return candidates }
	filtered: [dynamic]int
	for index, i in candidates {
		matches := true
		#partial switch _ in state.items[index].statement {
		case ^TSInterfaceDeclaration, ^TSTypeAliasDeclaration: matches = space == .Type
		case ^VariableDeclaration, ^FunctionDeclaration: matches = space == .Value
		}
		if !matches && filtered.allocator.procedure == nil {
			filtered = make([dynamic]int, 0, len(candidates))
			append(&filtered, ..candidates[:i])
		} else if matches && filtered.allocator.procedure != nil { append(&filtered, index) }
	}
	if filtered.allocator.procedure != nil { return filtered[:] }
	return candidates
}

@(private)
dts_declares_value :: proc(stmt: Statement) -> bool {
	#partial switch _ in stmt {
	case ^TSInterfaceDeclaration, ^TSTypeAliasDeclaration: return false
	}
	return true
}
