package kessel

import "core:slice"

JSXHelper :: enum { JSX, JSXS, JSXDEV, Fragment, CreateElement }
JSX_HELPER_NAMES := [JSXHelper]string{
	.JSX = "jsx", .JSXS = "jsxs", .JSXDEV = "jsxDEV", .Fragment = "Fragment", .CreateElement = "createElement",
}
JSXHelperModule :: enum { Runtime, Root }
JSXRuntimeImports :: struct {
	bindings: [JSXHelper]string,
	namespaces: [JSXHelperModule]string,
	first_module: Maybe(JSXHelperModule),
	filename_binding: string,
	line_offsets: []u32,
	source_position: SourceMapPosition,
}

// A key after a spread must override any key supplied by that spread.
// React's createElement API preserves their original order in the props object.
jsx_needs_create_element :: proc(opening: ^JSXOpeningElement) -> bool {
	if opening == nil { return false }
	spread := false
	for attr in opening.attributes {
		switch item in attr {
		case ^JSXSpreadAttribute: spread = true
		case JSXAttribute:
			if key, ok := item.name.(JSXIdentifier); ok && spread && key.name == "key" { return true }
		}
	}
	return false
}

gen_jsx_automatic :: proc(cg: ^Codegen, opening: ^JSXOpeningElement, children: []JSXChild, location: JSXSourceLocation) {
	first, second := -1, -1
	first_text: string
	for child, i in children {
		text, present := jsx_child_value(cg, child)
		if !present { continue }
		if first >= 0 { second = i; break }
		first, first_text = i, text
	}
	helper := JSXHelper.JSXS if second >= 0 else JSXHelper.JSX
	if cg.cfg.jsx.development { helper = .JSXDEV }
	gen_jsx_helper(cg, helper)
	cg_byte(cg, '(')
	if opening == nil { gen_jsx_helper(cg, .Fragment) } else { gen_jsx_classic_name(cg, opening.name) }
	cg_byte(cg, ',')
	cg_space(cg)
	emitted := false
	key: ^Expression
	if opening != nil {
		for attr in opening.attributes {
			if item, ok := attr.(JSXAttribute); ok {
				if name, named := item.name.(JSXIdentifier); named && name.name == "key" {
					key = item.value.? or_else nil
					if key == nil { cg_strip_unsupported(cg, name.loc, "JSX key requires a value") }
					continue
				}
			}
			gen_jsx_prop(cg, attr, &emitted)
		}
	}
	if first >= 0 {
		gen_jsx_prop_start(cg, &emitted)
		cg_str(cg, "children:")
		cg_space(cg)
		gen_jsx_children_prop(cg, children, first, second, first_text)
	}
	if emitted { cg_space(cg); cg_byte(cg, '}') } else { cg_str(cg, "{}") }
	if key != nil {
		cg_byte(cg, ',')
		cg_space(cg)
		gen_jsx_classic_attr_value(cg, key)
	} else if cg.cfg.jsx.development { cg_str(cg, ",void 0") }
	if cg.cfg.jsx.development {
		cg_str(cg, ",true" if second >= 0 else ",false")
		if opening != nil {
			cg_byte(cg, ',')
			gen_jsx_source(cg, location)
			if !cg.jsx_omit_self { cg_str(cg, ",this") }
		}
	}
	cg_byte(cg, ')')
	jsx_finish_helper(cg, helper)
}

gen_jsx_children_prop :: proc(cg: ^Codegen, children: []JSXChild, first, second: int, text: string) {
	_, spread := children[first].(^JSXSpreadChild)
	array := second >= 0 || spread
	if array { cg_byte(cg, '[') }
	gen_jsx_child_value(cg, children[first], text)
	if second >= 0 {
		for child in children[second:] { gen_jsx_classic_child(cg, child) }
	}
	if array { cg_byte(cg, ']') }
}

gen_jsx_helper :: proc(cg: ^Codegen, helper: JSXHelper) {
	imports := &cg.runtime_scope.jsx_imports
	if cg.cfg.strip_module == .Script {
		module := JSXHelperModule.Root if helper == .CreateElement else JSXHelperModule.Runtime
		if imports.namespaces[module] == "" {
			imports.namespaces[module] = codegen_fresh_runtime_binding(cg, "react" if module == .Root else "jsx_runtime")
		}
		cg_str(cg, imports.namespaces[module])
		cg_byte(cg, '.')
		cg_str(cg, JSX_HELPER_NAMES[helper])
	} else {
		if imports.bindings[helper] == "" {
			imports.bindings[helper] = codegen_fresh_runtime_binding(cg, JSX_HELPER_NAMES[helper])
		}
		cg_str(cg, imports.bindings[helper])
	}
}

// JSX lowering visits nested elements before completing their parent. Static
// helper dependencies follow that order when the runtime has side effects.
jsx_finish_helper :: proc(cg: ^Codegen, helper: JSXHelper) {
	imports := &cg.runtime_scope.jsx_imports
	if imports.first_module == nil {
		imports.first_module = JSXHelperModule.Root if helper == .CreateElement else JSXHelperModule.Runtime
	}
}

// Collect only helpers actually emitted. Type erasure can remove JSX entirely.
// Insert their declarations once, keeping directives first and mappings aligned.
gen_jsx_runtime_imports :: proc(cg: ^Codegen, offset: int) {
	imports := &cg.runtime_scope.jsx_imports
	first, used := imports.first_module.?
	if !used && imports.filename_binding == "" { return }
	end := cg.pos
	line_start := cg.at_line_start
	script := cg.cfg.strip_module == .Script
	if !script { gen_jsx_filename_binding(cg) }
	if used {
		if script { first = .Root }
		gen_jsx_module_import(cg, first)
		gen_jsx_module_import(cg, .Runtime if first == .Root else .Root)
	}
	if script { gen_jsx_filename_binding(cg) }
	size := cg.pos - end
	assert(size > 0)
	assert(offset <= end)
	slice.rotate_right(cg.buf[offset:cg.pos], size)
	cg.at_line_start = line_start
	if cg.sm != nil {
		for &record in cg.sm.records {
			if record.gen_offset >= u32(offset) { record.gen_offset += u32(size) }
		}
	}
}

gen_jsx_module_import :: proc(cg: ^Codegen, module: JSXHelperModule) {
	imports := &cg.runtime_scope.jsx_imports
	suffix := "/jsx-runtime" if module == .Runtime else ""
	if module == .Runtime && cg.cfg.jsx.development { suffix = "/jsx-dev-runtime" }
	if cg.cfg.strip_module == .Script {
		if imports.namespaces[module] == "" { return }
		cg_str(cg, "var ")
		cg_str(cg, imports.namespaces[module])
		cg_str(cg, "=require(")
		gen_string_quoted(cg, cg.cfg.jsx.import_source, suffix)
		cg_str(cg, ");")
	} else {
		emitted := false
		for helper in JSXHelper {
			if (module == .Root) != (helper == .CreateElement) || imports.bindings[helper] == "" { continue }
			if emitted { cg_byte(cg, ','); cg_space(cg) } else { cg_module_keyword(cg, "import {") }
			cg_str(cg, JSX_HELPER_NAMES[helper])
			cg_str(cg, " as ")
			cg_str(cg, imports.bindings[helper])
			emitted = true
		}
		if !emitted { return }
		cg_str(cg, "} from ")
		gen_string_quoted(cg, cg.cfg.jsx.import_source, suffix)
		cg_byte(cg, ';')
	}
	cg_newline(cg)
}
