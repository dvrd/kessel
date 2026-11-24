package kessel

import "core:mem"
import "core:slice"
import "core:strings"

DeclarationDiagnostic :: struct {
	code, message: string,
	start, end: u32,
}

DeclarationOutput :: struct {
	output: string,
	errors: [dynamic]DeclarationDiagnostic,
}

DeclarationVisibility :: enum { Local, Export, Default }

DeclarationItem :: struct {
	statement: Statement,
	group, part: int,
	name: string,
	visibility: DeclarationVisibility,
	region, child: int,
	selected, root: bool,
	text: string,
	errors: [dynamic]DeclarationDiagnostic,
}

DeclarationReference :: struct { name: string, loc: Loc, value, qualified: bool }
DeclarationConditional :: struct { constraint, result: Loc }
DeclarationScope :: struct { name: string, loc: Loc, value: bool }

DeclarationEmit :: struct {
	writer: Codegen,
	job: ^ParseJob,
	enums: EnumConstants,
	semantic: SemanticModel,
	enum_scopes: map[u32]ScopeId,
	external_enum_members: map[SemanticBindingKey]bool,
	items: [dynamic]DeclarationItem,
	regions: [dynamic]DeclarationRegion,
	namespaces: map[DeclarationNamespaceKey]int,
	exports: map[DeclarationNamespaceKey][dynamic]int,
	region, current_item: int,
	queue: [dynamic]int,
	references: [dynamic]DeclarationReference,
	scopes: [dynamic]DeclarationScope,
	conditionals: [dynamic]DeclarationConditional,
	output: DeclarationOutput,
	module: bool,
	default_name: string,
}

// The queue starts at exports. Printing a signature discovers the declarations
// it refers to, so private implementations are never needed to infer the API.
declarations_generate :: proc(job: ^ParseJob, allocator: mem.Allocator) -> DeclarationOutput {
	context.allocator = allocator
	state := DeclarationEmit{job = job}
	state.output.errors = make([dynamic]DeclarationDiagnostic, allocator)
	for err in job.parser.errors {
		append(&state.output.errors, DeclarationDiagnostic{"Invalid_Syntax", err.message, err.start, err.end})
	}
	if len(state.output.errors) != 0 { return state.output }
	if job.lang != .TS && job.lang != .TSX {
		dts_error(&state, "Unsupported_Input", "Declaration generation requires a TypeScript source file.", {})
		return state.output
	}
	if job.source_is_dts {
		state.output.output = string(job.source.data)
		return state.output
	}
	state.module = job.program.type == .Module || job.is_commonjs || dts_external_module(job)
	codegen_init(&state.writer, {indent = "    "}, string(job.source.data), allocator)
	dts_index_regions(&state)
	state.default_name = "_default"
	for (state.default_name in state.regions[0].bindings) {
		state.default_name = strings.concatenate({state.default_name, "_1"}, allocator)
	}
	state.writer.declaration_emit = &state
	for head := 0; head < len(state.queue); head += 1 {
		state.current_item = state.queue[head]
		item := &state.items[state.current_item]
		state.region = item.region
		clear(&state.references)
		clear(&state.scopes)
		clear(&state.conditionals)
		state.writer.pos = 0
		state.writer.depth = state.regions[item.region].depth
		state.writer.at_line_start = false
		dts_emit_item(&state, item)
		item.text = strings.clone(string(state.writer.buf[:state.writer.pos]), allocator)
		for reference in state.references {
			if dts_reference_is_local(&state, reference) { continue }
			space := DeclarationBindingSpace.Value if reference.value else DeclarationBindingSpace.Type
			if reference.loc == (Loc{}) { space = .Either } // A local export can be a type or a value.
			for index in dts_lookup(&state, reference.name, space) { dts_select(&state, index) }
		}
	}
	for region, index in state.regions {
		if !region.active { continue }
		state.region = index
		dts_function_assignments(&state)
	}
	dts_finish(&state)
	// Discovery follows dependencies and member groups. Report diagnostics
	// in source order, including distinct errors on the same computed name.
	slice.sort_by(state.output.errors[:], proc(a, b: DeclarationDiagnostic) -> bool {
		if a.start != b.start { return a.start < b.start }
		if a.end != b.end { return a.end < b.end }
		if a.code != b.code { return a.code < b.code }
		return a.message < b.message
	})
	// One source construct can be printed twice, such as a parameter property
	// and its constructor parameter. Report each distinct diagnostic once.
	unique := 0
	for diagnostic in state.output.errors {
		if unique > 0 && diagnostic == state.output.errors[unique - 1] { continue }
		state.output.errors[unique] = diagnostic
		unique += 1
	}
	resize(&state.output.errors, unique)
	return state.output
}

// `import x = require("m")` and `export =` make a file an external module even
// when the parser classifies it as a script, so its locals are not global.
@(private)
dts_external_module :: proc(job: ^ParseJob) -> bool {
	for stmt in job.program.body {
		assert(stmt != nil)
		#partial switch s in stmt^ {
		case ^TSExportAssignment: return true
		case ^TSImportEqualsDeclaration:
			if _, external := s.module_reference.(^TSExternalModuleReference); external { return true }
		}
	}
	return false
}

@(private)
dts_select :: proc(state: ^DeclarationEmit, index: int) {
	if state.items[index].selected { return }
	state.items[index].selected = true
	append(&state.queue, index)
}

@(private)
dts_add :: proc(state: ^DeclarationEmit, stmt: Statement, group, part: int, name: string, visibility: DeclarationVisibility, root: bool) {
	index := len(state.items)
	append(&state.items, DeclarationItem{statement = stmt, region = state.region, group = group, part = part, name = name, visibility = visibility, root = root})
	if name != "" { dts_bind(state, name, index) }
	if root && state.region == 0 { dts_select(state, index) }
}

@(private)
dts_bind :: proc(state: ^DeclarationEmit, name: string, index: int) {
	region := &state.regions[state.region]
	indices := region.bindings[name]
	append(&indices, index)
	region.bindings[name] = indices
	if state.region != 0 && (state.items[index].visibility == .Export || region.ambient) {
		key := DeclarationNamespaceKey{region.symbol, name}
		members := state.exports[key]
		append(&members, index)
		state.exports[key] = members
	}
}

@(private)
dts_index :: proc(state: ^DeclarationEmit, statement: Statement, group: int) {
	stmt := statement
	visibility := DeclarationVisibility.Local
	#partial switch s in statement {
	case ^ExportNamedDeclaration:
		visibility = .Export
		if d, ok := s.declaration.?; ok { stmt = decl_to_stmt(d^) } else { state.regions[state.region].marker = true }
	case ^ExportDefaultDeclaration:
		visibility = .Default
		if d, ok := s.declaration^.(^Declaration); ok { stmt = decl_to_stmt(d^) } else { state.regions[state.region].marker = true }
	case ^ExportAllDeclaration, ^TSExportAssignment, ^TSNamespaceExportDeclaration:
		visibility = .Export
		state.regions[state.region].marker = true
	}
	root := visibility != .Local || (state.region == 0 && !state.module) || state.regions[state.region].ambient
	name: string
	#partial switch s in stmt {
	case ^VariableDeclaration:
		for v, part in s.declarations {
			if id, ok := v.id.(^Identifier); ok { name = id.name } else { name = "" }
			dts_add(state, stmt, group, part, name, visibility, root)
			if name == "" {
				names: [dynamic]string
				collect_pattern_bound_names_list(v.id, &names)
				for binding in names { dts_bind(state, binding, len(state.items) - 1) }
			}
		}
		return
	case ^ImportDeclaration:
		for spec, part in s.specifiers {
			dts_add(state, stmt, group, part, import_spec_local_name(spec), .Local, false)
		}
		if len(s.specifiers) == 0 && !dts_empty_import_clause(state, s) { dts_add(state, stmt, group, -1, "", .Local, true) }
		return
	case ^FunctionDeclaration: if id, ok := s.id.?; ok { name = id.name }
	case ^ClassDeclaration: if id, ok := s.id.?; ok { name = id.name }
	case ^TSTypeAliasDeclaration: name = s.id.name
	case ^TSInterfaceDeclaration: name = s.id.name
	case ^TSEnumDeclaration: name = s.id.name
	case ^TSImportEqualsDeclaration:
		name = s.id.name
		// An unexported alias inside a namespace is private to that block.
		if visibility == .Local && state.region != 0 { root = false }
	case ^TSModuleDeclaration:
		if id, ok := s.id^.(^Identifier); ok { name = id.name }
		if s.global || name == "" { root = true }
	case ^ExportNamedDeclaration, ^ExportDefaultDeclaration, ^ExportAllDeclaration, ^TSExportAssignment, ^TSNamespaceExportDeclaration:
	case: return
	}
	dts_add(state, stmt, group, -1, name, visibility, root)
}

@(private)
dts_prefix :: proc(cg: ^Codegen, visibility: DeclarationVisibility, ambient: bool) {
	if visibility == .Default { cg_str(cg, "export default "); return }
	if visibility == .Export { cg_str(cg, "export ") }
	if ambient { cg_str(cg, "declare ") }
}

@(private)
dts_error :: proc(state: ^DeclarationEmit, code, message: string, loc: Loc) {
	diagnostic := DeclarationDiagnostic{code, message, loc.start, loc.end}
	if len(state.items) == 0 { append(&state.output.errors, diagnostic); return }
	append(&state.items[state.current_item].errors, diagnostic)
}

@(private)
dts_emit_item :: proc(state: ^DeclarationEmit, item: ^DeclarationItem) {
	cg := &state.writer
	#partial switch s in item.statement {
	case ^ImportDeclaration: // Reassemble selected imports in original order below.
	case ^VariableDeclaration: dts_variable(state, s, item.part)
	case ^FunctionDeclaration:
		if !s.no_body {
			for index in state.regions[state.region].bindings[item.name] {
				if sig, ok := state.items[index].statement.(^FunctionDeclaration); ok && sig.no_body { return }
			}
		}
		dts_function(state, s, get_statement_loc(state.regions[state.region].body[item.group]))
	case ^TSModuleDeclaration:
		dts_namespace_header(state, s)
		if item.child != 0 {
			child := &state.regions[item.child]
			child.active = true
			for index := child.first; index < child.end; index += 1 {
				if state.items[index].root { dts_select(state, index) }
			}
		}
	case ^TSImportEqualsDeclaration:
		if ref, entity := s.module_reference.(^Expression); entity { dts_reference(state, ref, true) }
		gen_ts_import_equals_full(cg, s)
	case ^TSEnumDeclaration: dts_enum(state, s)
	case ^ClassDeclaration: dts_class(state, s)
	case ^TSInterfaceDeclaration:
		dts_type_parameters(state, s.type_parameters, s.loc)
		for base in s.extends { dts_reference(state, base.expression, false) }
		gen_ts_interface_declaration_full(cg, s)
	case ^TSTypeAliasDeclaration:
		dts_type_parameters(state, s.type_parameters, s.loc)
		gen_ts_type_alias_declaration_full(cg, s)
	case ^ExportNamedDeclaration:
		if s.source == nil {
			for spec in s.specifiers {
				local := convert_export_spec_name(spec.local)
				append(&state.references, DeclarationReference{name = local.name})
			}
		}
		gen_statement(cg, item.statement)
	case ^ExportAllDeclaration, ^TSNamespaceExportDeclaration: gen_statement(cg, item.statement)
	case ^ExportDefaultDeclaration: dts_default(state, s.declaration^.(^Expression), "export default ")
	case ^TSExportAssignment: dts_default(state, s.expression, "export = ")
	case:
		dts_error(state, "Unsupported_Declaration", "This declaration form is not supported yet.", get_statement_loc(&item.statement))
	}
}

// The AST has zero specifiers for both bare imports and empty named imports.
// Only the bare import is retained for its side effects in declaration output.
@(private)
dts_empty_import_clause :: proc(state: ^DeclarationEmit, decl: ^ImportDeclaration) -> bool {
	prefix := state.writer.source[decl.loc.start:decl.source.loc.start]
	lexer: Lexer
	init_lexer(&lexer, prefix, context.allocator, .Module)
	return decl.import_kind == .Type || lex_token(&lexer).kind == .LBrace
}

@(private)
dts_print_docs :: proc(state: ^DeclarationEmit, start: u32, cursor: ^int) {
	comments := state.job.lexer.comments[:]
	source := state.writer.source
	for cursor^ < len(comments) && comments[cursor^].end <= start { cursor^ += 1 }
	first := cursor^
	boundary := start
	for first > 0 {
		c := comments[first - 1]
		if !strings.has_prefix(source[c.start:c.end], "/**") || strings.trim_space(source[c.end:boundary]) != "" { break }
		first -= 1
		boundary = c.start
	}
	for c in comments[first:cursor^] { cg_str(&state.writer, source[c.start:c.end]); cg_newline(&state.writer) }
}
