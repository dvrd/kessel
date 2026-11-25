package kessel

import "core:fmt"

JSXSourceLocation :: struct { line, column: u32 }

// Collect each opening tag's original position before traversing its children.
// Byte offsets come from the parser. JSX tooling expects one-based UTF-16 columns.
jsx_source_location :: proc(cg: ^Codegen, start: u32) -> JSXSourceLocation {
	imports := &cg.runtime_scope.jsx_imports
	if imports.line_offsets == nil {
		imports.filename_binding = codegen_fresh_runtime_binding(cg, "jsx_filename")
		imports.line_offsets = source_line_offsets(cg.source, cg.runtime_scope.allocator)
	}
	line, column := sourcemap_position_at(cg.source, imports.line_offsets, start, &imports.source_position)
	return {line + 1, column + 1}
}

gen_jsx_source :: proc(cg: ^Codegen, location: JSXSourceLocation) {
	assert(location.line > 0)
	assert(location.column > 0)
	buffer: [64]byte
	cg_str(cg, "{fileName:")
	cg_str(cg, cg.runtime_scope.jsx_imports.filename_binding)
	cg_str(cg, fmt.bprintf(buffer[:], ",lineNumber:%d,columnNumber:%d}", location.line, location.column))
}

gen_jsx_filename_binding :: proc(cg: ^Codegen) {
	name := cg.runtime_scope.jsx_imports.filename_binding
	if name == "" { return }
	cg_str(cg, "var ")
	cg_str(cg, name)
	cg_byte(cg, '=')
	gen_string_quoted(cg, cg.cfg.jsx.filename)
	cg_byte(cg, ';')
	cg_newline(cg)
}
