package kessel

DeclarationPrintFrame :: struct { region, next: int }

// Visibility is known after the reachability walk. An ambient namespace can
// omit export modifiers only when every emitted declaration is public.
@(private)
dts_finish :: proc(state: ^DeclarationEmit) {
	cg := &state.writer
	cg.declaration_emit = nil
	cg.pos, cg.depth, cg.at_line_start = 0, 0, true
	for item in state.items {
		if !item.selected || item.visibility != .Local || item.text == "" { continue }
		if state.regions[item.region].ambient { continue }
		#partial switch s in item.statement {
		case ^TSImportEqualsDeclaration: continue
		case ^TSModuleDeclaration: if item.name == "" || s.global { continue }
		}
		state.regions[item.region].private_items = true
	}
	frames: [dynamic]DeclarationPrintFrame
	append(&frames, DeclarationPrintFrame{0, state.regions[0].first})
	comment_index := 0
	module_syntax := false // The root output contains an import or an export.
	for len(frames) > 0 {
		frame := &frames[len(frames) - 1]
		region := &state.regions[frame.region]
		cg.depth = region.depth
		if frame.next == region.end {
			// A module whose output has no import or export would read as a
			// global script. One with unexported declarations needs a marker so
			// they are not treated as exports of the declaration file.
			needs_marker := region.private_items && !region.marker
			if frame.region == 0 {
				needs_marker = state.module && (needs_marker || !module_syntax)
			}
			if needs_marker { cg_str(cg, "export {};"); cg_newline(cg) }
			if frame.region != 0 {
				cg.depth -= 1
				cg_byte(cg, '}')
				cg_newline(cg)
			}
			pop(&frames)
			continue
		}
		first := frame.next
		frame.next += 1
		for frame.next < region.end && state.items[frame.next].group == state.items[first].group { frame.next += 1 }
		items := state.items[first:frame.next]
		visible := false
		for item in items {
			if !item.selected { continue }
			append(&state.output.errors, ..item.errors[:])
			_, imported := item.statement.(^ImportDeclaration)
			if imported || item.text != "" { visible = true }
		}
		if !visible { continue }
		if frame.region == 0 && dts_module_indicator(items) { module_syntax = true }
		start := get_statement_loc(region.body[items[0].group]).start
		dts_print_docs(state, start, &comment_index)
		dts_print_group(state, items, region)
		child := items[0].child
		if child != 0 { append(&frames, DeclarationPrintFrame{child, state.regions[child].first}) }
	}
	if len(state.output.errors) == 0 { state.output.output = string(cg.buf[:cg.pos]) }
}

// Import attributes describe how a runtime loads a module. A declaration file
// keeps only `resolution-mode`, which selects the types a specifier resolves to.
@(private)
dts_declaration_attributes :: proc(
	attributes: [dynamic]ImportAttribute,
) -> [dynamic]ImportAttribute {
	if len(attributes) != 1 { return nil }
	attribute := attributes[0]
	if attribute.key.name != "resolution-mode" { return nil }
	if attribute.value.value != "import" && attribute.value.value != "require" { return nil }
	return attributes
}

@(private)
dts_module_indicator :: proc(items: []DeclarationItem) -> bool {
	assert(len(items) > 0)
	for item in items {
		if !item.selected { continue }
		if item.visibility != .Local { return true }
		#partial switch _ in item.statement {
		case ^ImportDeclaration, ^TSImportEqualsDeclaration: return true
		}
	}
	return false
}

@(private)
dts_print_group :: proc(state: ^DeclarationEmit, items: []DeclarationItem, region: ^DeclarationRegion) {
	cg := &state.writer
	item := items[0]
	visibility := item.visibility
	if region.depth > 0 && !region.private_items && !region.marker && visibility == .Export {
		visibility = .Local
	}
	ambient := region.depth == 0
	#partial switch s in item.statement {
	case ^ImportDeclaration:
		clause := s^
		clause.specifiers = nil
		clause.attributes = dts_declaration_attributes(s.attributes)
		for entry in items {
			if entry.selected && entry.part >= 0 { append(&clause.specifiers, s.specifiers[entry.part]) }
		}
		gen_import_declaration(cg, &clause)
	case ^VariableDeclaration:
		dts_prefix(cg, visibility, ambient)
		switch s.kind {
		case .Var: cg_str(cg, "var ")
		case .Let: cg_str(cg, "let ")
		case .Const, .Using, .AwaitUsing: cg_str(cg, "const ")
		}
		first := true
		for entry in items {
			if !entry.selected { continue }
			if !first { cg_str(cg, ", ") }
			cg_str(cg, entry.text)
			first = false
		}
		cg_byte(cg, ';')
	case ^TSModuleDeclaration:
		dts_prefix(cg, visibility, ambient)
		cg_str(cg, item.text)
		cg_str(cg, " {" if item.child != 0 else ";")
	case ^FunctionDeclaration, ^ClassDeclaration, ^TSEnumDeclaration:
		dts_prefix(cg, visibility, ambient)
		cg_str(cg, item.text)
	case ^TSInterfaceDeclaration, ^TSTypeAliasDeclaration:
		dts_prefix(cg, visibility, false)
		cg_str(cg, item.text)
	case ^TSImportEqualsDeclaration:
		dts_prefix(cg, item.visibility, false)
		cg_str(cg, item.text)
	case: cg_str(cg, item.text)
	}
	cg_newline(cg)
}
