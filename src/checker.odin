package main

// ============================================================================
// Semantic Checker — Pass 3 of the kessel pipeline.
//
// Walks a finished AST and enforces ECMA-262 Early Errors that do NOT affect
// parsing decisions. The parser (pass 2) builds the tree permissively; this
// pass validates it.
//
// Architecture mirrors OXC's `oxc_semantic/src/checker/javascript.rs`:
// ancestor-walking checks rather than flag-threading during parse.
//
// Currently a stub — checks will be migrated from the parser incrementally.
// The full list of planned checks (previously inline in the parser):
//
//   • break / continue outside loop / switch
//   • break label / continue label target validation
//   • duplicate label declarations
//   • super.x outside method
//   • super() outside derived constructor
//   • new.target outside function
//   • yield in generator params
//   • await in async params
//   • 'arguments' in static block
//   • 'return' in static block
//   • 'using' / 'await using' in case clause
//   • duplicate __proto__ in object literal
//   • strict-mode parameter validation (after 'use strict' directive)
//   • duplicate private class members
//   • duplicate parameter names
//   • eval / arguments binding in strict mode
//   • with statement in strict mode
//   • duplicate exported names
//   • private field not declared in enclosing class
//   • ... and other §12-§16 early errors
//
// ============================================================================

import "core:fmt"
import "core:mem"

Checker :: struct {
	errors: [dynamic]ParseError,
	allocator: mem.Allocator,
}

init_checker :: proc(alloc: mem.Allocator) -> Checker {
	return Checker{
		errors = make([dynamic]ParseError, 0, 8, alloc),
		allocator = alloc,
	}
}

// check_program is the entry point for the semantic checker.
// Call after parse_program to validate early errors.
check_program :: proc(c: ^Checker, program: ^Program) {
	// Stub — checks will be migrated here from the parser.
	// For now, this is a no-op. The parser has been stripped of
	// validation-only checks, making it permissive like OXC's parser.
	_ = c
	_ = program
}
