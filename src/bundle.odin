package kessel

// ============================================================================
// Bundler (`kessel bundle`) — design note.
// ============================================================================
//
// Module graph. Starting from one entry file, every import/export-from
// statement, literal `require("x")` call and literal `import("x")` call
// becomes a BundleRecord resolved through the native resolver. TypeScript and
// JSX inputs are lowered to JavaScript by the existing transformer first; the
// bundler then parses that JavaScript again and links plain JS only, so the
// linker never has to reason about types or elided imports. JSON files become
// a synthetic `module.exports = <json>` CommonJS module. Each module keeps its
// own ParseJob, semantic model and record list. Cycles are legal.
//
// Linking strategy. Three shapes exist per module (BundleWrap):
//   • None — an ES module that is only ever imported statically. Its top-level
//     statements are scope-hoisted into the bundle scope. Top-level bindings
//     are renamed for uniqueness through the semantic model and every import
//     binding reference is rewritten to the exporting module's binding, so
//     live bindings and TDZ fall out of ordinary JavaScript scoping.
//   • CJS — a CommonJS module. Its body is kept inside
//     `__commonJS(function (exports, module) { ... })` and runs on first
//     `require_x()` call. ES importers read it through `__toESM(require_x())`.
//   • ESM — an ES module that must evaluate lazily because CommonJS code
//     requires it, something imports it dynamically, or a wrapped module
//     imports it statically (the closure rule: dependencies of a lazy module
//     must be lazy too, otherwise they would run before they are asked for).
//     Its body lives in `__esm(function () { ... })`; consumers read exports
//     through a getter-based namespace object, which keeps bindings live.
// Evaluation order is the ES post-order over static imports. Calls that start
// a wrapped dependency are emitted at the importing position in that order,
// not at the top of the importing module, so `import cjs; import esm` keeps
// its relative order.
//
// Tree shaking. Hoisted modules are split into top-level statements. A
// statement is kept when it has side effects (conservative analysis that
// honours `/* @__PURE__ */`) and its module is included, or when a kept
// statement references a binding it declares. A module from a package with
// `"sideEffects": false` is included only when one of its bindings is used.
// Wrapped modules are all-or-nothing.
//
// Output. A single file in ESM, CommonJS or IIFE format, an optional
// multi-source source map composed through the transformer and printer maps,
// and optional minification by re-running the existing minifier over the
// finished bundle. All formats run every module in strict mode.
//
// Limits (fixed upper bounds; exceeding one is a diagnostic, never a crash):
//   • BUNDLE_MODULES_MAX modules and BUNDLE_SOURCE_BYTES_MAX input bytes.
//   • BUNDLE_RESOLVE_DEPTH_MAX hops when following re-export chains.
//   • BUNDLE_AST_DEPTH_MAX nested expressions in the bundler's own AST walk.
//
// Not supported yet. Each is reported as an error rather than bundled wrongly:
// code splitting and multiple entries; top-level await outside the entry;
// `export *` from a CommonJS module; a namespace object over a module that
// uses `export *` from an external; direct eval in an ES module; `import.meta`
// outside ESM output; TypeScript `import x = require()` and `export =`;
// loaders other than JS, TS, JSX and JSON.
//
// Known differences from running the modules unbundled. These are inherent to
// the design and shared with other scope-hoisting bundlers:
//   • Every module runs in strict mode, including CommonJS written for sloppy
//     mode. Syntax that strict mode forbids fails the final validation.
//   • A binding renamed to resolve a collision, and an anonymous default
//     export, report the new name through `Function.prototype.name`.
//   • In ESM output external imports are hoisted, so externals evaluate before
//     all bundled code. __filename and __dirname name the bundle.
//   • The interop namespace of a CommonJS module lists every own property of
//     module.exports in definition order; Node lists only the names it can
//     detect statically, sorted.
// ============================================================================

import "core:fmt"
import "core:mem"
import mvirtual "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:strings"

BUNDLE_MODULES_MAX       :: 1 << 16
BUNDLE_SOURCE_BYTES_MAX  :: 1 << 30
BUNDLE_RESOLVE_DEPTH_MAX :: 128
BUNDLE_AST_DEPTH_MAX     :: 4096
BUNDLE_EXTERNAL          :: i32(-1)
BUNDLE_UNRESOLVED        :: i32(-2)
// The anonymous default export has no source name. An invalid identifier
// cannot collide with a declared binding.
BUNDLE_DEFAULT_LOCAL     :: "*default*"

#assert(BUNDLE_MODULES_MAX <= int(max(i32)))
#assert(BUNDLE_SOURCE_BYTES_MAX <= int(max(u32)))

BundleFormat   :: enum u8 { ESM, CJS, IIFE }
BundlePlatform :: enum u8 { Node, Browser }

BundleOptions :: struct {
	entry:        string,
	format:       BundleFormat,
	platform:     BundlePlatform,
	externals:    []string,
	conditions:   []string,
	main_fields:  []string, // empty: resolver default for the platform
	tsconfig:     string,
	map_directory: string,  // where the source map will live; "" keeps display paths
	global_name:  string,   // IIFE only
	jsx:          string,   // "classic" or "automatic"
	jsx_import_source: string,
	jsx_factory:  string,   // classic runtime; empty selects React.createElement
	jsx_fragment: string,
	jsx_development: bool,
	// Handed to the transformer unchanged. Any of them makes plain
	// JavaScript inputs go through the transformer as well.
	define:       map[string]string, // global or member name to replacement expression
	target:       string,            // "es2015" to "es2024"; empty keeps the syntax as written
	decorators:   string,            // "legacy" lowers TypeScript experimental decorators
	emit_decorator_metadata: bool,
	minify:       bool,
	source_map:   bool,
	tree_shaking: bool,
}

BundleSeverity :: enum u8 { Error, Warning }

BundleDiagnostic :: struct {
	severity: BundleSeverity,
	path:     string, // "" when the diagnostic has no file
	line:     u32,    // one-based; zero when unknown
	column:   u32,    // one-based
	message:  string,
}

BundleModuleKind :: enum u8 { ESM, CJS }
BundleWrap       :: enum u8 { None, CJS, ESM }
BundleRecordKind :: enum u8 { Import, Require, Dynamic }

// One dependency edge. `node` is the expression slot that the emitter
// rewrites for require() and import() calls; statements need no slot.
BundleRecord :: struct {
	kind:      BundleRecordKind,
	specifier: string,
	loc:       Loc,
	statement: i32,          // index of the enclosing top-level statement
	target:    i32,          // module index, BUNDLE_EXTERNAL or BUNDLE_UNRESOLVED
	node:      ^Expression,
	used:      bool,         // a kept statement reads a binding through this record
	optional:  bool,         // require() inside a try block: failure is the caller's to handle
}

BundleImport :: struct {
	record: i32,
	name:   string, // "*" selects the namespace
}

BundleExport :: struct {
	record: i32,    // -1 for a local binding
	name:   string, // local root name, or the name requested from the record
	loc:    Loc,
}

BundleTargetKind :: enum u8 { Missing, Ambiguous, Symbol, Namespace, Property, External }

// Where an imported name finally lives.
//   Symbol:    root binding `name` of hoisted module `module`.
//   Namespace: the namespace object of ES module `module`.
//   Property:  property `name` of wrapped module `module` ("" is the whole
//              interop object of a CommonJS module).
//   External:  export `name` of the external requested by `via` ("*" is the
//              namespace).
// `via_module`/`via_record` name the record that directly reaches a wrapped or
// external module; its importer decides the default-export interop mode.
BundleTarget :: struct {
	kind:       BundleTargetKind,
	module:     i32,
	name:       string,
	via_module: i32,
	via_record: i32,
}

BundlePart :: struct {
	loc:          Loc,
	declares:     [dynamic]string,
	uses:         [dynamic]string, // root names read or written by the statement
	side_effects: bool,
	live:         bool,
}

BundleModule :: struct {
	index:    i32,
	path:     string, // absolute; unique key
	display:  string, // relative to the working directory, for comments and maps
	original: string, // text the user wrote; source-map content
	source:   string, // JavaScript the linker parses
	transform_records: []SourceMapRecord, // link offsets back to `original`
	job:      ^ParseJob,
	model:    SemanticModel,

	kind:      BundleModuleKind,
	wrap:      BundleWrap,
	node_mode: bool, // Node's own ESM rules: a CommonJS default is module.exports
	typescript: bool, // unused imports may name types the transformer kept
	side_effect_free: bool,
	has_top_level_await, has_import_meta, has_hashbang: bool,
	direct_eval: Maybe(u32), // offset of a direct eval() call, which reads bindings by name
	uses_commonjs_objects: bool, // reads a free `module` or `exports`
	lazy: bool, // required or imported dynamically somewhere

	records: [dynamic]BundleRecord,
	imports: map[string]BundleImport,
	exports: map[string]BundleExport,
	export_order: [dynamic]string,
	stars:   [dynamic]i32,
	this_nodes: [dynamic]^Expression,
	callees: map[u32]bool,          // identifier offsets used as a callee or tag
	free_cjs: map[u32]bool,         // unresolved `require` reference offsets
	resolved: map[string]BundleTarget,   // export name to its final home
	resolving: map[string]bool,          // cycle guard for `export *` loops
	import_targets: map[string]BundleTarget, // local import binding to its home
	export_names: []string,         // sorted; includes names reached through `export *`
	export_names_done: bool,

	parts:    []BundlePart,
	declared: map[string][dynamic]i32,
	included: bool,
	needs_namespace: bool,
	visit_state: u8,

	names:          map[string]string, // original root name to final bundle name
	wrapper_name:   string,
	namespace_name: string,
	default_name:   string,
	interop_names:  [2]string, // per importer mode; "" until some importer needs it
}

BundleExternalImport :: struct {
	specifier: string,
	bare:      bool,
	names:     map[string]string, // imported name to bundle binding
	order:     [dynamic]string,
	interop_names: [2]string,     // non-ESM formats read through an interop object
}

BundleGraph :: struct {
	options:     BundleOptions,
	arena:       mvirtual.Arena,
	alloc:       mem.Allocator,
	modules:     [dynamic]^BundleModule,
	by_path:     map[string]i32,
	packages:    map[string]BundlePackage,
	diagnostics: [dynamic]BundleDiagnostic,
	error_count: int,
	source_bytes: int,
	working_dir: string,

	externals:      [dynamic]BundleExternalImport,
	external_index: map[string]i32,
	names:          BundleNames,
	helpers:        BundleHelpers,
	order:          [dynamic]BundleEvent,
}

BundleOutput :: struct {
	code:     string,
	map_json: string, // "" unless a source map was requested
}

// bundle_run builds the graph, links it and prints the bundle. The caller
// reads diagnostics from the graph and must call bundle_destroy afterwards.
// Failure is reported through `ok`; no partial output is ever returned.
bundle_run :: proc(g: ^BundleGraph, options: BundleOptions) -> (output: BundleOutput, ok: bool) {
	assert(options.entry != "")
	g.options = options
	if err := mvirtual.arena_init_growing(&g.arena); err != nil { return {}, false }
	g.alloc = mvirtual.arena_allocator(&g.arena)
	context.allocator = g.alloc
	g.modules = make([dynamic]^BundleModule, g.alloc)
	g.by_path = make(map[string]i32, g.alloc)
	g.packages = make(map[string]BundlePackage, g.alloc)
	g.diagnostics = make([dynamic]BundleDiagnostic, g.alloc)
	g.externals = make([dynamic]BundleExternalImport, g.alloc)
	g.external_index = make(map[string]i32, g.alloc)
	g.order = make([dynamic]BundleEvent, g.alloc)
	if cwd, err := os.get_working_directory(g.alloc); err == nil { g.working_dir = cwd }

	// Each phase depends on the previous one being error-free: linking a
	// graph with a missing module would only produce follow-on noise.
	bundle_graph_load(g)
	if g.error_count != 0 { return {}, false }
	bundle_link(g)
	if g.error_count != 0 { return {}, false }
	bundle_shake(g)
	bundle_order(g)
	if g.error_count != 0 { return {}, false }
	bundle_names_assign(g)
	output = bundle_emit(g)
	if g.error_count != 0 { return {}, false }
	return output, true
}

bundle_destroy :: proc(g: ^BundleGraph) {
	for module in g.modules {
		if module.job != nil { parse_job_close(module.job) }
	}
	mvirtual.arena_destroy(&g.arena)
	g^ = {}
}

bundle_error :: proc(
	g: ^BundleGraph,
	module: ^BundleModule,
	offset: Maybe(u32),
	format: string,
	args: ..any,
) {
	bundle_report(g, .Error, module, offset, fmt.aprintf(format, ..args, allocator = g.alloc))
}

bundle_warning :: proc(
	g: ^BundleGraph,
	module: ^BundleModule,
	offset: Maybe(u32),
	format: string,
	args: ..any,
) {
	bundle_report(g, .Warning, module, offset, fmt.aprintf(format, ..args, allocator = g.alloc))
}

@(private="file")
bundle_report :: proc(
	g: ^BundleGraph,
	severity: BundleSeverity,
	module: ^BundleModule,
	offset: Maybe(u32),
	message: string,
) {
	diagnostic := BundleDiagnostic{severity = severity, message = message}
	if module != nil {
		diagnostic.path = module.display
		if at, located := offset.?; located {
			diagnostic.line, diagnostic.column = bundle_original_position(module, at)
		}
	}
	if severity == .Error { g.error_count += 1 }
	append(&g.diagnostics, diagnostic)
}

// A link offset points into the transformed JavaScript. Diagnostics and source
// maps must cite the text the user wrote, so walk back through the
// transformer's map. Plain JavaScript modules have no map and map to
// themselves.
bundle_original_offset :: proc(
	module: ^BundleModule,
	offset: u32,
) -> (original: u32, mapped: bool) {
	records := module.transform_records
	if records == nil { return offset, true }
	lo, hi := 0, len(records)
	for lo < hi {
		mid := (lo + hi) / 2
		if records[mid].gen_offset <= offset { lo = mid + 1 } else { hi = mid }
	}
	if lo == 0 { return 0, false }
	return records[lo - 1].src_offset, true
}

@(private="file")
bundle_original_position :: proc(module: ^BundleModule, offset: u32) -> (line, column: u32) {
	original, mapped := bundle_original_offset(module, offset)
	if !mapped { return 0, 0 }
	text := module.original
	end := min(int(original), len(text))
	line = 1
	line_start := 0
	for i in 0..<end {
		if text[i] == '\n' { line += 1; line_start = i + 1 }
	}
	return line, u32(end - line_start) + 1
}

bundle_display_path :: proc(g: ^BundleGraph, path: string) -> string {
	if g.working_dir != "" {
		if relative, err := filepath.rel(g.working_dir, path, g.alloc); err == .None {
			if !strings.has_prefix(relative, "..") { return relative }
		}
	}
	return path
}

// A JavaScript identifier stem derived from a file path, used to name the
// bundle's synthetic bindings (`require_stem`, `stem_exports`, ...).
bundle_path_stem :: proc(g: ^BundleGraph, path: string) -> string {
	base := filepath.base(path)
	if dot := strings.index_byte(base, '.'); dot > 0 { base = base[:dot] }
	if base == "index" {
		parent := filepath.base(filepath.dir(path))
		if parent != "" && parent != "." && parent != "/" { base = parent }
	}
	buffer := make([dynamic]byte, 0, len(base) + 1, g.alloc)
	for i in 0..<len(base) {
		c := base[i]
		letter := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' || c == '$'
		digit := c >= '0' && c <= '9'
		if letter || (digit && len(buffer) > 0) { append(&buffer, c) } else { append(&buffer, '_') }
	}
	if len(buffer) == 0 { append(&buffer, '_') }
	return string(buffer[:])
}
