package kessel

// Printing one module: rewrite its AST for the bundle scope, then hand it to
// the ordinary printer. The printer's rename table carries binding renames
// and import rewrites; whole-expression replacements (require(), import())
// are spliced into the AST as identifier nodes holding the finished text.

import "core:fmt"
import "core:strings"

// A stretch of the bundle body printed from one module, with the printer's
// offsets into that module's link source.
BundleSegment :: struct {
	module:  i32,
	base:    u32,
	size:    u32,
	records: []SourceMapRecord,
}

BundleEmit :: struct {
	g:        ^BundleGraph,
	body:     strings.Builder,
	segments: [dynamic]BundleSegment,
}

// The text that denotes an import target in the bundle. A property read used
// as a callee is wrapped as `(0, object.name)` so the call keeps an undefined
// receiver, as a call through an import binding has.
bundle_target_text :: proc(g: ^BundleGraph, target: BundleTarget, callee: bool) -> string {
	builder := strings.builder_make(g.alloc)
	member := false
	switch target.kind {
	case .Missing, .Ambiguous:
		panic("unresolved import targets are rejected before printing")
	case .Symbol:
		module := g.modules[target.module]
		if target.name == BUNDLE_DEFAULT_LOCAL { return module.default_name }
		if final, renamed := module.names[target.name]; renamed { return final }
		return target.name
	case .Namespace:
		return g.modules[target.module].namespace_name
	case .Property:
		module := g.modules[target.module]
		if module.kind == .CJS {
			node_mode := g.modules[target.via_module].node_mode
			strings.write_string(&builder, bundle_interop_name(g, module, node_mode))
		} else {
			strings.write_string(&builder, module.namespace_name)
		}
		if target.name != "" {
			bundle_write_accessor(&builder, target.name)
			member = true
		}
	case .External:
		importer := g.modules[target.via_module]
		external := bundle_external_for(g, importer.records[target.via_record].specifier)
		if g.options.format == .ESM { return bundle_external_binding(g, external, target.name) }
		strings.write_string(&builder,
			bundle_external_interop_name(g, external, importer.node_mode))
		if target.name != "*" {
			bundle_write_accessor(&builder, target.name)
			member = true
		}
	}
	text := strings.to_string(builder)
	if callee && member { return fmt.aprintf("(0, %s)", text, allocator = g.alloc) }
	return text
}

// The statement that starts wrapped module `record.target` on behalf of an
// importer, binding the interop object when the importer reads through it.
bundle_init_text :: proc(g: ^BundleGraph, importer: ^BundleModule, record: BundleRecord) -> string {
	target := g.modules[record.target]
	assert(target.wrap != .None)
	if target.wrap == .ESM { return fmt.aprintf("%s();", target.wrapper_name, allocator = g.alloc) }
	if !record.used { return fmt.aprintf("%s();", target.wrapper_name, allocator = g.alloc) }
	g.helpers.used += {.ToESM, .CopyProps, .DefProp}
	return fmt.aprintf("%s = %s(%s(), %d);", bundle_interop_name(g, target, importer.node_mode),
		g.helpers.names[.ToESM], target.wrapper_name, 1 if importer.node_mode else 0,
		allocator = g.alloc)
}

// `{ name: () => binding, ... }` for a namespace object. Getters keep the
// exports live and defer every read until a consumer asks.
bundle_write_export_getters :: proc(
	g: ^BundleGraph,
	builder: ^strings.Builder,
	module: ^BundleModule,
	indent: string,
) {
	strings.write_string(builder, "{\n")
	for name in bundle_export_names(g, module) {
		target := bundle_resolve_hoisted(g, module, name, 0)
		strings.write_string(builder, indent)
		strings.write_string(builder, "  ")
		if bundle_is_identifier(name) {
			strings.write_string(builder, name)
		} else {
			write_json_string(builder, name)
		}
		strings.write_string(builder, ": () => ")
		strings.write_string(builder, bundle_target_text(g, target, false))
		strings.write_string(builder, ",\n")
	}
	strings.write_string(builder, indent)
	strings.write_string(builder, "}")
}

bundle_print_module :: proc(e: ^BundleEmit, module: ^BundleModule, depth: int) {
	g := e.g
	assert(module.included)
	assert(module.job != nil)
	renamed := make(map[u32]string, g.alloc)
	bundle_print_renames(g, module, &renamed)
	bundle_print_records(g, module, &renamed)
	kept := make([]bool, len(module.job.program.body), g.alloc)
	statements := bundle_print_statements(g, module, kept)
	comments := bundle_print_comments(g, module, kept)
	if g.options.format == .CJS && module.wrap == .None {
		// CommonJS gives the file a `this`; an ES module's is undefined.
		for slot in module.this_nodes {
			replacement := new(Identifier, g.alloc)
			replacement^ = {loc = loc_from_expr(slot), name = "(void 0)"}
			slot^ = replacement
		}
	}

	cg: Codegen
	codegen_init(&cg, CodegenConfig{indent = "  "}, module.source, g.alloc)
	cg.renamed = renamed
	cg.depth = depth
	sm: SourceMap
	sourcemap_init(&sm, module.source)
	codegen_enable_sourcemap(&cg, &sm)
	program := module.job.program^
	program.body = statements
	codegen_program(&cg, &program, comments)
	if cg.pos != 0 && cg.buf[cg.pos - 1] != '\n' { cg_byte(&cg, '\n') }

	base := strings.builder_len(e.body)
	strings.write_bytes(&e.body, cg.buf[:cg.pos])
	append(&e.segments, BundleSegment{
		module = module.index, base = u32(base), size = u32(cg.pos), records = sm.records[:],
	})
}

@(private="file")
bundle_print_renames :: proc(g: ^BundleGraph, module: ^BundleModule, renamed: ^map[u32]string) {
	model := &module.model
	if module.kind == .ESM {
		for ref in model.refs {
			if ref.resolved == SYMBOL_UNRESOLVED { continue }
			if model.symbols[ref.resolved].scope != SCOPE_ROOT {
				continue
			}
			if ref.name in module.imports {
				target := bundle_import_target(g, module, ref.name)
				// Only an unused type import of a TypeScript source reaches here unresolved.
				if target.kind == .Missing { continue }
				renamed[ref.start] = bundle_target_text(g, target, module.callees[ref.start])
			} else if final, known := module.names[ref.name]; known && final != ref.name {
				renamed[ref.start] = final
			}
		}
		for id in model.scopes[SCOPE_ROOT].symbols {
			symbol := model.symbols[id]
			if final, known := module.names[symbol.name]; known && final != symbol.name {
				renamed[symbol.decl_start] = final
			}
		}
	}
	// Outside CommonJS output there is no `require` in scope. What the
	// bundler could not resolve statically goes through the runtime shim.
	if g.options.format != .CJS && len(module.free_cjs) != 0 {
		for start in module.free_cjs { renamed[start] = g.helpers.names[.Require] }
	}
}

@(private="file")
bundle_print_records :: proc(g: ^BundleGraph, module: ^BundleModule, renamed: ^map[u32]string) {
	shim_needed := g.options.format != .CJS && len(module.free_cjs) != 0
	replaced := 0
	for &record in module.records {
		if record.kind == .Import || record.node == nil || record.target < 0 { continue }
		if module.wrap == .None && !module.parts[record.statement].live { continue }
		target := g.modules[record.target]
		assert(target.wrap != .None, "a lazily loaded module must be wrapped")
		text: string
		switch {
		case record.kind == .Require && target.wrap == .CJS:
			text = fmt.aprintf("%s()", target.wrapper_name, allocator = g.alloc)
		case record.kind == .Require:
			g.helpers.used += {.ToCommonJS, .CopyProps, .DefProp, .Namespace}
			text = fmt.aprintf("%s(%s())", g.helpers.names[.ToCommonJS], target.wrapper_name,
				allocator = g.alloc)
		case target.wrap == .CJS:
			g.helpers.used += {.ToESM, .CopyProps, .DefProp}
			text = fmt.aprintf("Promise.resolve().then(() => %s(%s(), %d))",
				g.helpers.names[.ToESM],
				target.wrapper_name, 1 if module.node_mode else 0, allocator = g.alloc)
		case:
			text = fmt.aprintf("Promise.resolve().then(%s)", target.wrapper_name,
				allocator = g.alloc)
		}
		replacement := new(Identifier, g.alloc)
		replacement^ = {loc = record.loc, name = text}
		record.node^ = replacement
		if record.kind == .Require {
			delete_key(renamed, record.loc.start)
			replaced += 1
		}
	}
	if shim_needed && replaced < len(module.free_cjs) { g.helpers.used += {.Require} }
}

@(private="file")
bundle_print_statement :: proc(g: ^BundleGraph, value: Statement) -> ^Statement {
	statement := new(Statement, g.alloc)
	statement^ = value
	return statement
}

@(private="file")
bundle_print_rename_function :: proc(
	module: ^BundleModule,
	function: ^FunctionDeclaration,
	fallback: BindingIdentifier,
) {
	id, named := function.id.?
	if !named { id = fallback }
	if final, known := module.names[id.name]; known { id.name = final }
	function.id = id
}

@(private="file")
bundle_print_rename_class :: proc(
	module: ^BundleModule,
	class: ^ClassDeclaration,
	fallback: BindingIdentifier,
) {
	id, named := class.id.?
	if !named { id = fallback }
	if final, known := module.names[id.name]; known { id.name = final }
	class.id = id
}

// Turn module syntax into plain declarations. Imports and re-exports vanish:
// the rename table already points their uses at the real bindings.
@(private="file")
bundle_print_statements :: proc(
	g: ^BundleGraph,
	module: ^BundleModule,
	kept: []bool,
) -> [dynamic]^Statement {
	body := module.job.program.body[:]
	out := make([dynamic]^Statement, 0, len(body), g.alloc)
	for statement, index in body {
		before := len(out)
		defer kept[index] = len(out) != before
		if module.kind == .CJS {
			append(&out, statement)
			continue
		}
		if module.wrap == .None && !module.parts[index].live { continue }
		#partial switch node in statement^ {
		case ^ImportDeclaration, ^ExportAllDeclaration:
		case ^ExpressionStatement:
			// A directive in the middle of the bundle scope means nothing.
			if node.directive == "" { append(&out, statement) }
		case ^FunctionDeclaration:
			bundle_print_rename_function(module, node, {})
			append(&out, statement)
		case ^ClassDeclaration:
			bundle_print_rename_class(module, node, {})
			append(&out, statement)
		case ^ExportNamedDeclaration:
			declaration, has_declaration := node.declaration.?
			if !has_declaration { continue }
			#partial switch inner in declaration^ {
			case ^FunctionDeclaration:
				bundle_print_rename_function(module, inner, {})
				append(&out, bundle_print_statement(g, inner))
			case ^ClassDeclaration:
				bundle_print_rename_class(module, inner, {})
				append(&out, bundle_print_statement(g, inner))
			case ^VariableDeclaration:
				append(&out, bundle_print_statement(g, inner))
			}
		case ^ExportDefaultDeclaration:
			append(&out, bundle_print_default(g, module, node))
		case:
			append(&out, statement)
		}
	}
	return out
}

// A comment travels with the statement it sits in or precedes. Comments of
// statements that were removed would otherwise describe code that is gone.
// Licence comments always stay.
@(private="file")
bundle_print_comments :: proc(g: ^BundleGraph, module: ^BundleModule, kept: []bool) -> []Comment {
	body := module.job.program.body[:]
	out := make([dynamic]Comment, 0, len(module.job.lexer.comments), g.alloc)
	next := 0 // first statement that ends after the current comment starts
	for comment in module.job.lexer.comments {
		for next < len(body) && get_statement_loc(body[next]).end <= comment.start { next += 1 }
		if next == len(body) || kept[next] || codegen_comment_kind(comment) == .Legal {
			append(&out, comment)
		}
	}
	return out[:]
}

// `export default` becomes a declaration of the module's default binding.
// An anonymous function stays a hoisted function declaration, so a cyclic
// importer can still call it before this module's statements have run.
@(private="file")
bundle_print_default :: proc(
	g: ^BundleGraph,
	module: ^BundleModule,
	node: ^ExportDefaultDeclaration,
) -> ^Statement {
	at := Loc{node.loc.start, node.loc.start}
	fallback := BindingIdentifier{loc = at, name = module.default_name}
	switch inner in node.declaration^ {
	case ^Declaration:
		#partial switch declaration in inner^ {
		case ^FunctionDeclaration:
			bundle_print_rename_function(module, declaration, fallback)
			return bundle_print_statement(g, declaration)
		case ^ClassDeclaration:
			bundle_print_rename_class(module, declaration, fallback)
			return bundle_print_statement(g, declaration)
		}
		panic("a default export in plain JavaScript is a function, class or expression")
	case ^Expression:
		id := new(Identifier, g.alloc)
		id^ = {loc = at, name = module.default_name}
		declaration := new(VariableDeclaration, g.alloc)
		declaration^ = {loc = node.loc, kind = .Const, declarations = make(
			[dynamic]VariableDeclarator, 1, g.alloc)}
		declaration.declarations[0] = {loc = node.loc, id = id, init = inner}
		return bundle_print_statement(g, declaration)
	}
	panic("an export default declaration always has a body")
}
