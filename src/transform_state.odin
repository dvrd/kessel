package kessel

import "core:mem"
import "core:strings"

// Shared state for the lowering transforms that run while the printer walks
// the tree: decorators, target lowering and React Refresh. The printer holds
// one pointer to it, nil unless a lowering was requested, so every hook in
// codegen.odin costs a single nil check on the ordinary printing path.

TransformDecorators :: enum u8 { Preserve, Legacy, Standard }

// Helpers are emitted as hoisted function declarations at the end of the
// program, once, and only when a lowering used them. Each gets a binding
// that cannot collide with a name in the source.
TransformHelper :: enum u8 { Decorate, Decorate_Param, Decorate_Metadata }

TransformState :: struct {
	job:           ^ParseJob,
	allocator:     mem.Allocator,
	decorators:    TransformDecorators,
	emit_metadata: bool,
	helpers:       [TransformHelper]string, // Empty until the helper is first used.
	model:         ^SemanticModel,          // Built on first use; most files never need it.
	enums:         EnumConstants,           // Enum declarations found while building the model.
}

// Reads of intrinsics inside a helper resolve in module scope, so a source
// binding with the same name would silently replace the intrinsic.
TRANSFORM_HELPER_GLOBALS := [TransformHelper][]string{
	.Decorate          = {"Object", "Reflect"},
	.Decorate_Param    = {},
	.Decorate_Metadata = {"Reflect"},
}

TRANSFORM_HELPER_KINDS := [TransformHelper]string{
	.Decorate          = "decorate",
	.Decorate_Param    = "param",
	.Decorate_Metadata = "metadata",
}

// Every line ends a statement or opens or closes a block, so the compact
// printer can join the trimmed lines without changing the token stream.
TRANSFORM_HELPER_BODIES := [TransformHelper]string{
	.Decorate = `(decorators, target, key, desc) {
  var c = arguments.length;
  var r = c < 3 ? target : desc === null ? desc = Object.getOwnPropertyDescriptor(target, key) : desc;
  if (typeof Reflect === "object" && typeof Reflect.decorate === "function") {
    r = Reflect.decorate(decorators, target, key, desc);
  } else {
    for (var i = decorators.length - 1; i >= 0; i--) {
      var d = decorators[i];
      if (d) r = (c < 3 ? d(r) : c > 3 ? d(target, key, r) : d(target, key)) || r;
    }
  }
  if (c > 3 && r) Object.defineProperty(target, key, r);
  return r;
}`,
	.Decorate_Param = `(index, decorator) {
  return function (target, key) {
    decorator(target, key, index);
  };
}`,
	.Decorate_Metadata = `(key, value) {
  if (typeof Reflect === "object" && typeof Reflect.metadata === "function") {
    return Reflect.metadata(key, value);
  }
}`,
}

transform_state_init :: proc(
	job: ^ParseJob, cg: ^Codegen, options: TransformOptions) -> Maybe(StripDiagnostic,
) {
	assert(job != nil)
	assert(cg.transform == nil)
	decorators: TransformDecorators
	switch options.decorators {
	case "", "preserve": decorators = .Preserve
	case "legacy":       decorators = .Legacy
	case "standard":     decorators = .Standard
	case: return StripDiagnostic{what = "expected decorators mode preserve, legacy, or standard"}
	}
	if options.emit_decorator_metadata && decorators != .Legacy {
		return StripDiagnostic{what = "decorator metadata requires legacy decorators"}
	}
	if decorators == .Standard {
		return StripDiagnostic{what = "standard decorators are not lowered yet"}
	}
	if decorators == .Preserve { return nil }
	state := new(TransformState, job.arena_alloc)
	state^ = {
		job = job, allocator = job.arena_alloc,
		decorators = decorators, emit_metadata = options.emit_decorator_metadata,
	}
	cg.transform = state
	return nil
}

transform_helper :: proc(cg: ^Codegen, helper: TransformHelper) -> string {
	state := cg.transform
	assert(state != nil)
	if state.helpers[helper] == "" {
		state.helpers[helper] = codegen_fresh_runtime_binding(cg, TRANSFORM_HELPER_KINDS[helper])
		for name in TRANSFORM_HELPER_GLOBALS[helper] {
			if codegen_resource_root_binding(cg, name) {
				cg_strip_unsupported(cg, {}, "a top-level binding shadows a global the lowering helpers need")
			}
		}
	}
	return state.helpers[helper]
}

// Function declarations hoist, so the helpers are callable from the first statement.
transform_finish_program :: proc(cg: ^Codegen) {
	state := cg.transform
	if state == nil { return }
	for name, helper in state.helpers {
		if name == "" { continue }
		cg_str(cg, "function ")
		cg_str(cg, name)
		remaining := TRANSFORM_HELPER_BODIES[helper]
		for line in strings.split_iterator(&remaining, "\n") {
			cg_str(cg, strings.trim_space(line) if cg.cfg.minified else line)
			cg_newline(cg)
		}
	}
}

transform_model :: proc(cg: ^Codegen) -> ^SemanticModel {
	state := cg.transform
	assert(state != nil)
	if state.model == nil {
		state.model = new(SemanticModel, state.allocator)
		enum_constants_init(&state.enums, state.allocator, len(cg.source))
		state.model^ = semantic_build(
			state.job.program, cg.source, state.job.lang, state.allocator, enum_constants = &state.enums,
		)
	}
	return state.model
}

// Synthesized nodes sit at the start of the construct they replace, with an
// empty span, so no comment or annotation lookup can match them.
transform_expression :: proc(state: ^TransformState, node: ^$T) -> ^Expression {
	expression := new(Expression, state.allocator)
	expression^ = node
	return expression
}

transform_identifier :: proc(state: ^TransformState, name: string, at: u32) -> ^Expression {
	assert(name != "")
	node := new(Identifier, state.allocator)
	node^ = {loc = {at, at}, name = name}
	return transform_expression(state, node)
}

transform_assignment :: proc(
	state: ^TransformState, target, value: ^Expression, at: u32,
) -> ^Expression {
	assert(target != nil)
	assert(value != nil)
	node := new(AssignmentExpression, state.allocator)
	node^ = {loc = {at, at}, operator = .Assign, left = target, right = value}
	return transform_expression(state, node)
}

// Every expression the printer emits passes through here once, after type
// erasure, so a lowering can substitute an equivalent tree before it prints.
transform_lower_expression :: proc(cg: ^Codegen, expr: ^Expression) -> ^Expression {
	state := cg.transform
	assert(state != nil)
	assert(expr != nil)
	if class, is_class := expr^.(^ClassExpression); is_class {
		if state.decorators == .Legacy { transform_legacy_class_expression(cg, class) }
	}
	return expr
}
