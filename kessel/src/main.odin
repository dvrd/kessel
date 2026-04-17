package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"

import lexer "./lexer"
import parser "./parser"
import ast "./ast"

// ============================================================================
// Main Entry Point
// ============================================================================

main :: proc() {
	if len(os.args) < 2 {
		print_usage()
		os.exit(1)
	}
	
	command := os.args[1]
	
	switch command {
	case "parse":
		if len(os.args) < 3 {
			fmt.println("Error: parse command requires a file path")
			fmt.println("Usage: kessel parse <js-file>")
			os.exit(1)
		}
		file_path := os.args[2]
		parse_file(file_path)
		
	case "lex", "tokenize":
		if len(os.args) < 3 {
			fmt.println("Error: lex command requires a file path")
			fmt.println("Usage: kessel lex <js-file>")
			os.exit(1)
		}
		file_path := os.args[2]
		lex_file(file_path)
		
	case "help", "-h", "--help":
		print_usage()
		
	case "version", "-v", "--version":
		fmt.println("kessel version 0.1.0")
		
	case:
		fmt.printf("Unknown command: %s\n", command)
		print_usage()
		os.exit(1)
	}
}

print_usage :: proc() {
	fmt.println("Kessel - Fast JavaScript Parser")
	fmt.println("")
	fmt.println("Usage: kessel <command> [options]")
	fmt.println("")
	fmt.println("Commands:")
	fmt.println("  parse <file>     Parse a JavaScript file and output AST as JSON")
	fmt.println("  lex <file>       Tokenize a JavaScript file and output tokens")
	fmt.println("  test             Run lexer debug test")
	fmt.println("  help             Show this help message")
	fmt.println("  version          Show version information")
	fmt.println("")
	fmt.println("Examples:")
	fmt.println("  kessel parse app.js")
	fmt.println("  kessel lex src/index.js")
}

// ============================================================================
// Parse Command
// ============================================================================

parse_file :: proc(file_path: string) {
	// Read file
	source, read_err := os.read_entire_file_from_path(file_path, context.allocator)
	if read_err != nil {
		fmt.printf("Error: Could not read file: %s\n", file_path)
		os.exit(1)
	}
	defer delete(source, context.allocator)
	
	// Create arena for allocations with smart pre-sizing
	arena: mem.Arena
	estimated_size := lexer.estimate_arena_size(len(source))
	backing := make([]byte, estimated_size)
	defer delete(backing, context.allocator)
	mem.arena_init(&arena, backing)
	arena_alloc := mem.arena_allocator(&arena)
	
	fmt.eprintf("Arena pre-sized: %d bytes (source: %d bytes)\n", estimated_size, len(source))
	
	// Initialize optimized lexer with compact tokens + SIMD
	lex: lexer.LexerAdapter
	lexer.init_adapter(&lex, string(source), &arena)
	
	// Initialize parser with optimized lexer
	p: parser.Parser
	parser.init_parser_adapter(&p, &lex, &arena)
	
	// Parse program
	program := parser.parse_program(&p, .Script)
	
	// Check for errors
	if len(p.errors) > 0 {
		fmt.printf("Parse errors (%d):\n", len(p.errors))
		for err in p.errors {
			fmt.printf("  Line %d, Column %d: %s\n", err.loc.line, err.loc.column, err.message)
		}
	}
	
	// Output AST as JSON-like structure
	fmt.println("{")
	print_program_ast(program, 1)
	fmt.println("}")
	
	// Print statistics
	fmt.eprintf("\n--- Statistics ---\n")
	fmt.eprintf("Arena used: %d bytes\n", arena.peak_used)
	fmt.eprintf("Parse errors: %d\n", len(p.errors))
}

// ============================================================================
// AST Printing (JSON-like output)
// ============================================================================

print_indent :: proc(indent: int) {
	for i in 0..<indent {
		fmt.print("  ")
	}
}

print_program_ast :: proc(program: ^ast.Program, indent: int) {
	print_indent(indent)
	type_str := "Script" if program.type == .Script else "Module"
	fmt.printf("\"type\": \"%s\",\n", type_str)
	
	print_indent(indent)
	fmt.println("\"body\": [")
	
	for stmt, i in program.body {
		print_indent(indent + 1)
		fmt.println("{")
		print_statement_ast(stmt, indent + 2)
		print_indent(indent + 1)
		if i < len(program.body) - 1 {
			fmt.println("},")
		} else {
			fmt.println("}")
		}
	}
	
	print_indent(indent)
	fmt.println("]")
}

print_statement_ast :: proc(stmt: ^ast.Statement, indent: int) {
	print_indent(indent)
	fmt.printf("\"type\": \"%s\"", get_statement_type_name(stmt))
	
	#partial switch s in stmt^ {
	case ^ast.ExpressionStatement:
		fmt.println(",")
		print_indent(indent)
		fmt.println("\"expression\": {")
		print_expression_ast(s.expression, indent + 1)
		print_indent(indent)
		fmt.print("}")
		
	case ^ast.VariableDeclaration:
		kind_str := "var"
		#partial switch s.kind {
		case .Let:   kind_str = "let"
		case .Const: kind_str = "const"
		}
		fmt.println(",")
		print_indent(indent)
		fmt.printf("\"kind\": \"%s\",\n", kind_str)
		print_indent(indent)
		fmt.println("\"declarations\": [")
		for decl, i in s.declarations {
			print_indent(indent + 1)
			fmt.println("{")
			print_indent(indent + 2)
			fmt.println("\"id\": {")
			print_pattern_ast(decl.id, indent + 3)
			print_indent(indent + 2)
			fmt.println("},")
			print_indent(indent + 2)
			fmt.print("\"init\": ")
			if init, ok := decl.init.(^ast.Expression); ok {
				fmt.println("{")
				print_expression_ast(init, indent + 3)
				print_indent(indent + 2)
				fmt.print("}")
			} else {
				fmt.print("null")
			}
			print_indent(indent + 1)
			if i < len(s.declarations) - 1 {
				fmt.println("},")
			} else {
				fmt.println("}")
			}
		}
		print_indent(indent)
		fmt.print("]")
		
	case ^ast.FunctionDeclaration:
		fmt.println(",")
		print_indent(indent)
		fmt.println("\"id\": {")
		if id, ok := s.expr.id.(ast.BindingIdentifier); ok {
			print_indent(indent + 1)
			fmt.printf("\"name\": \"%s\"\n", id.name)
		}
		print_indent(indent)
		fmt.println("},")
		print_indent(indent)
		fmt.printf("\"generator\": %v,\n", s.expr.generator)
		print_indent(indent)
		fmt.printf("\"async\": %v", s.expr.async)
		
	case ^ast.BlockStatement:
		fmt.println(",")
		print_indent(indent)
		fmt.println("\"body\": [")
		for inner_stmt, i in s.body {
			print_indent(indent + 1)
			fmt.println("{")
			print_statement_ast(inner_stmt, indent + 2)
			print_indent(indent + 1)
			if i < len(s.body) - 1 {
				fmt.println("},")
			} else {
				fmt.println("}")
			}
		}
		print_indent(indent)
		fmt.print("]")
		
	case ^ast.ReturnStatement:
		fmt.println(",")
		print_indent(indent)
		fmt.print("\"argument\": ")
		if arg, ok := s.argument.(^ast.Expression); ok {
			fmt.println("{")
			print_expression_ast(arg, indent + 1)
			print_indent(indent)
			fmt.print("}")
		} else {
			fmt.print("null")
		}
		
	case ^ast.IfStatement:
		fmt.println(",")
		print_indent(indent)
		fmt.println("\"test\": {")
		print_expression_ast(s.test, indent + 1)
		print_indent(indent)
		fmt.println("},")
		print_indent(indent)
		fmt.println("\"consequent\": {")
		print_statement_ast(s.consequent, indent + 1)
		print_indent(indent)
		fmt.println("},")
		print_indent(indent)
		fmt.print("\"alternate\": ")
		if alt, ok := s.alternate.(^ast.Statement); ok {
			fmt.println("{")
			print_statement_ast(alt, indent + 1)
			print_indent(indent)
			fmt.print("}")
		} else {
			fmt.print("null")
		}
		
	case ^ast.WhileStatement:
		fmt.println(",")
		print_indent(indent)
		fmt.println("\"test\": {")
		print_expression_ast(s.test, indent + 1)
		print_indent(indent)
		fmt.println("},")
		print_indent(indent)
		fmt.println("\"body\": {")
		print_statement_ast(s.body, indent + 1)
		print_indent(indent)
		fmt.print("}")
	
	case ^ast.ForStatement:
		fmt.println(",")
		print_indent(indent)
		fmt.print("\"init\": ")
		if decl, ok := s.init_decl.(^ast.VariableDeclaration); ok {
			fmt.println("{")
			print_statement_ast((^ast.Statement)(decl), indent + 1)
			print_indent(indent)
			fmt.println("},")
		} else if expr, ok := s.init_expr.(^ast.Expression); ok {
			fmt.println("{")
			print_expression_ast(expr, indent + 1)
			print_indent(indent)
			fmt.println("},")
		} else {
			fmt.println("null,")
		}
		print_indent(indent)
		fmt.print("\"test\": ")
		if test_expr, ok := s.test.(^ast.Expression); ok {
			fmt.println("{")
			print_expression_ast(test_expr, indent + 1)
			print_indent(indent)
			fmt.println("},")
		} else {
			fmt.println("null,")
		}
		print_indent(indent)
		fmt.print("\"update\": ")
		if upd_expr, ok := s.update.(^ast.Expression); ok {
			fmt.println("{")
			print_expression_ast(upd_expr, indent + 1)
			print_indent(indent)
			fmt.println("},")
		} else {
			fmt.println("null,")
		}
		print_indent(indent)
		fmt.println("\"body\": {")
		print_statement_ast(s.body, indent + 1)
		print_indent(indent)
		fmt.print("}")
	
	case ^ast.ClassDeclaration:
		fmt.println(",")
		print_indent(indent)
		fmt.print("\"id\": ")
		if id, ok := s.id.(ast.BindingIdentifier); ok {
			fmt.println("{")
			print_indent(indent + 1)
			fmt.println("\"type\": \"Identifier\",")
			print_indent(indent + 1)
			fmt.printf("\"name\": \"%s\"\n", id.name)
			print_indent(indent)
			fmt.println("},")
		} else {
			fmt.println("null,")
		}
		print_indent(indent)
		fmt.print("\"superClass\": ")
		if super, ok := s.super_class.(^ast.Expression); ok && super != nil {
			fmt.println("{")
			print_expression_ast(super, indent + 1)
			print_indent(indent)
			fmt.println("},")
		} else {
			fmt.println("null,")
		}
		print_indent(indent)
		fmt.print("\"body\": { ... }")
	
	case ^ast.TryStatement:
		fmt.println(",")
		print_indent(indent)
		fmt.println("\"block\": { ... },")
		print_indent(indent)
		fmt.print("\"handler\": ")
		if handler, ok := s.handler.(ast.CatchClause); ok {
			fmt.println("{")
			print_indent(indent + 1)
			fmt.println("\"type\": \"CatchClause\",")
			print_indent(indent + 1)
			fmt.print("\"param\": ")
			if param, ok2 := handler.param.(ast.Pattern); ok2 {
				fmt.println("{")
				print_pattern_ast(param, indent + 2)
				print_indent(indent + 1)
				fmt.println("},")
			} else {
				fmt.println("null,")
			}
			print_indent(indent + 1)
			fmt.println("\"body\": { ... }")
			print_indent(indent)
			fmt.println("},")
		} else {
			fmt.println("null,")
		}
		print_indent(indent)
		fmt.print("\"finalizer\": ")
		if fin, ok := s.finalizer.(ast.BlockStatement); ok {
			fmt.println("{")
			print_statement_ast((^ast.Statement)(&fin), indent + 1)
			print_indent(indent)
			fmt.print("}")
		} else {
			fmt.print("null")
		}
	
	case ^ast.ExportNamedDeclaration:
		fmt.println(",")
		print_indent(indent)
		fmt.print("\"specifiers\": [ ... ]")
	
	case ^ast.ExportDefaultDeclaration:
		fmt.println(",")
		print_indent(indent)
		fmt.print("\"declaration\": { ... }")
	
	case ^ast.ExportAllDeclaration:
		fmt.println(",")
		print_indent(indent)
		fmt.print("\"source\": { ... }")
	
	case ^ast.DoWhileStatement:
		fmt.println(",")
		print_indent(indent)
		fmt.println("\"body\": {")
		print_statement_ast(s.body, indent + 1)
		print_indent(indent)
		fmt.println("},")
		print_indent(indent)
		fmt.print("\"test\": { ... }")
	
	case ^ast.SwitchStatement:
		fmt.println(",")
		print_indent(indent)
		fmt.print("\"discriminant\": { ... },\n")
		print_indent(indent)
		fmt.print("\"cases\": [ ... ]")
	
	case ^ast.ForInStatement:
		fmt.println(",")
		print_indent(indent)
		fmt.print("\"left\": ")
		if decl, ok := s.left_decl.(^ast.VariableDeclaration); ok {
			fmt.println("{")
			print_statement_ast((^ast.Statement)(decl), indent + 1)
			print_indent(indent)
			fmt.println("},")
		} else if expr, ok := s.left_expr.(^ast.Expression); ok {
			fmt.println("{")
			print_expression_ast(expr, indent + 1)
			print_indent(indent)
			fmt.println("},")
		} else {
			fmt.println("null,")
		}
		print_indent(indent)
		fmt.println("\"right\": {")
		print_expression_ast(s.right, indent + 1)
		print_indent(indent)
		fmt.println("},")
		print_indent(indent)
		fmt.println("\"body\": {")
		print_statement_ast(s.body, indent + 1)
		print_indent(indent)
		fmt.print("}")
	
	case ^ast.ForOfStatement:
		fmt.println(",")
		print_indent(indent)
		fmt.print("\"left\": ")
		if decl, ok := s.left_decl.(^ast.VariableDeclaration); ok {
			fmt.println("{")
			print_statement_ast((^ast.Statement)(decl), indent + 1)
			print_indent(indent)
			fmt.println("},")
		} else if expr, ok := s.left_expr.(^ast.Expression); ok {
			fmt.println("{")
			print_expression_ast(expr, indent + 1)
			print_indent(indent)
			fmt.println("},")
		} else {
			fmt.println("null,")
		}
		print_indent(indent)
		fmt.println("\"right\": {")
		print_expression_ast(s.right, indent + 1)
		print_indent(indent)
		fmt.println("},")
		print_indent(indent)
		fmt.print("\"await\": ")
		if s.await {
			fmt.println("true,")
		} else {
			fmt.println("false,")
		}
		print_indent(indent)
		fmt.println("\"body\": {")
		print_statement_ast(s.body, indent + 1)
		print_indent(indent)
		fmt.print("}")
		print_indent(indent)
		fmt.print("\"await\": false,\n")
		print_indent(indent)
		fmt.print("\"body\": { ... }")
	
	case ^ast.ThrowStatement:
		fmt.println(",")
		print_indent(indent)
		fmt.print("\"argument\": { ... }")
	
	case ^ast.ImportDeclaration:
		fmt.println(",")
		print_indent(indent)
		fmt.print("\"specifiers\": [ ... ],\n")
		print_indent(indent)
		fmt.print("\"source\": { ... }")
	
	case ^ast.BreakStatement:
		fmt.println(",")
		print_indent(indent)
		fmt.print("\"label\": null")
	
	case ^ast.ContinueStatement:
		fmt.println(",")
		print_indent(indent)
		fmt.print("\"label\": null")
	
	case ^ast.LabeledStatement:
		fmt.println(",")
		print_indent(indent)
		fmt.print("\"label\": { ... },\n")
		print_indent(indent)
		fmt.print("\"body\": { ... }")
	
	case ^ast.WithStatement:
		fmt.println(",")
		print_indent(indent)
		fmt.print("\"object\": { ... },\n")
		print_indent(indent)
		fmt.print("\"body\": { ... }")
	
	case ^ast.EmptyStatement:
		// No additional fields
		
	case ^ast.DebuggerStatement:
		// No additional fields
		
	case:
		fmt.printf(",\n")
		print_indent(indent)
		fmt.printf("\"[UNIMPLEMENTED]\": true")
	}
}

print_pattern_ast :: proc(pattern: ast.Pattern, indent: int) {
	#partial switch p in pattern {
	case ^ast.Identifier:
		print_indent(indent)
		fmt.println("\"type\": \"Identifier\",")
		print_indent(indent)
		fmt.printf("\"name\": \"%s\"", p.name)
	case ^ast.ArrayPattern:
		print_indent(indent)
		fmt.println("\"type\": \"ArrayPattern\",")
		print_indent(indent)
		fmt.println("\"elements\": [")
		for elem, i in p.elements {
			if e, ok := elem.(ast.Pattern); ok {
				print_pattern_ast(e, indent + 1)
				if i < len(p.elements) - 1 {
					fmt.println(",")
				}
			}
		}
		print_indent(indent)
		fmt.print("]")
	case ^ast.ObjectPattern:
		print_indent(indent)
		fmt.println("\"type\": \"ObjectPattern\",")
		print_indent(indent)
		fmt.println("\"properties\": [ ... ]") // Simplified for now
	case:
		print_indent(indent)
		fmt.print("null")
	}
}

print_expression_ast :: proc(expr: ^ast.Expression, indent: int) {
	print_indent(indent)
	fmt.printf("\"type\": \"%s\"", get_expression_type_name(expr))
	
	#partial switch e in expr^ {
	case ast.Identifier:
		fmt.println(",")
		print_indent(indent)
		fmt.printf("\"name\": \"%s\"", e.name)
		
	case ast.NumericLiteral:
		fmt.println(",")
		print_indent(indent)
		fmt.printf("\"value\": %v,\n", e.value)
		print_indent(indent)
		fmt.printf("\"raw\": \"%s\"", e.raw)
		
	case ast.StringLiteral:
		fmt.println(",")
		print_indent(indent)
		fmt.printf("\"value\": \"%s\"", e.value)
		
	case ast.BooleanLiteral:
		fmt.println(",")
		print_indent(indent)
		fmt.printf("\"value\": %v", e.value)
		
	case ast.NullLiteral:
		// No additional fields
		
	case ast.ThisExpression:
		// No additional fields
		
	case ast.ArrayExpression:
		fmt.println(",")
		print_indent(indent)
		fmt.println("\"elements\": [")
		for elem, i in e.elements {
			if el, ok := elem.(^ast.Expression); ok {
				print_indent(indent + 1)
				fmt.println("{")
				print_expression_ast(el, indent + 2)
				print_indent(indent + 1)
				if i < len(e.elements) - 1 {
					fmt.println("},")
				} else {
					fmt.println("}")
				}
			}
		}
		print_indent(indent)
		fmt.print("]")
		
	case ast.ObjectExpression:
		fmt.println(",")
		print_indent(indent)
		fmt.println("\"properties\": [")
		for prop, i in e.properties {
			print_indent(indent + 1)
			fmt.println("{")
			print_indent(indent + 2)
			kind_str := "init"
			#partial switch prop.kind {
			case .Get: kind_str = "get"
			case .Set: kind_str = "set"
			case .Method: kind_str = "method"
			}
			fmt.printf("\"kind\": \"%s\",\n", kind_str)

			// Spread properties have nil key
			if prop.key != nil {
				print_indent(indent + 2)
				fmt.println("\"key\": {")
				print_expression_ast(prop.key, indent + 3)
				print_indent(indent + 2)
				fmt.println("},")
			} else {
				print_indent(indent + 2)
				fmt.println("\"key\": null,")
			}

			if prop.value != nil {
				print_indent(indent + 2)
				fmt.println("\"value\": {")
				print_expression_ast(prop.value, indent + 3)
				print_indent(indent + 2)
				fmt.print("}")
			} else {
				print_indent(indent + 2)
				fmt.print("\"value\": null")
			}

			print_indent(indent + 1)
			if i < len(e.properties) - 1 {
				fmt.println("},")
			} else {
				fmt.println("}")
			}
		}
		print_indent(indent)
		fmt.print("]")
		
	case ast.BinaryExpression:
		fmt.println(",")
		print_indent(indent)
		op_str := binary_op_to_string(e.operator)
		fmt.printf("\"operator\": \"%s\",\n", op_str)
		print_indent(indent)
		fmt.println("\"left\": {")
		print_expression_ast(e.left, indent + 1)
		print_indent(indent)
		fmt.println("},")
		print_indent(indent)
		fmt.println("\"right\": {")
		print_expression_ast(e.right, indent + 1)
		print_indent(indent)
		fmt.print("}")
		
	case ast.UnaryExpression:
		fmt.println(",")
		print_indent(indent)
		op_str := unary_op_to_string(e.operator)
		fmt.printf("\"operator\": \"%s\",\n", op_str)
		print_indent(indent)
		fmt.printf("\"prefix\": %v,\n", e.prefix)
		print_indent(indent)
		fmt.println("\"argument\": {")
		print_expression_ast(e.argument, indent + 1)
		print_indent(indent)
		fmt.print("}")
		
	case ast.AssignmentExpression:
		fmt.println(",")
		print_indent(indent)
		op_str := assignment_op_to_string(e.operator)
		fmt.printf("\"operator\": \"%s\",\n", op_str)
		print_indent(indent)
		fmt.println("\"left\": {")
		print_expression_ast(e.left, indent + 1)
		print_indent(indent)
		fmt.println("},")
		print_indent(indent)
		fmt.println("\"right\": {")
		print_expression_ast(e.right, indent + 1)
		print_indent(indent)
		fmt.print("}")
		
	case ast.CallExpression:
		fmt.println(",")
		print_indent(indent)
		fmt.println("\"callee\": {")
		print_expression_ast(e.callee, indent + 1)
		print_indent(indent)
		fmt.println("},")
		print_indent(indent)
		fmt.println("\"arguments\": [")
		for arg, i in e.arguments {
			print_indent(indent + 1)
			fmt.println("{")
			print_expression_ast(arg, indent + 2)
			print_indent(indent + 1)
			if i < len(e.arguments) - 1 {
				fmt.println("},")
			} else {
				fmt.println("}")
			}
		}
		print_indent(indent)
		fmt.print("]")
		
	case ast.MemberExpression:
		fmt.println(",")
		print_indent(indent)
		fmt.printf("\"computed\": %v,\n", e.computed)
		print_indent(indent)
		fmt.println("\"object\": {")
		print_expression_ast(e.object, indent + 1)
		print_indent(indent)
		fmt.println("},")
		print_indent(indent)
		fmt.println("\"property\": {")
		print_expression_ast(e.property, indent + 1)
		print_indent(indent)
		fmt.print("}")
		
	case ast.ConditionalExpression:
		fmt.println(",")
		print_indent(indent)
		fmt.println("\"test\": {")
		print_expression_ast(e.test, indent + 1)
		print_indent(indent)
		fmt.println("},")
		print_indent(indent)
		fmt.println("\"consequent\": {")
		print_expression_ast(e.consequent, indent + 1)
		print_indent(indent)
		fmt.println("},")
		print_indent(indent)
		fmt.println("\"alternate\": {")
		print_expression_ast(e.alternate, indent + 1)
		print_indent(indent)
		fmt.print("}")
		
	case ast.FunctionExpression:
		fmt.println(",")
		print_indent(indent)
		fmt.printf("\"generator\": %v,\n", e.generator)
		print_indent(indent)
		fmt.printf("\"async\": %v,\n", e.async)
		print_indent(indent)
		fmt.println("\"params\": [ ... ],")
		print_indent(indent)
		fmt.print("\"body\": { ... }")
		
	case ast.ArrowFunctionExpression:
		fmt.println(",")
		print_indent(indent)
		fmt.printf("\"expression\": %v,\n", e.expression)
		print_indent(indent)
		fmt.printf("\"async\": %v", e.async)
	
	case ast.NewExpression:
		fmt.println(",")
		print_indent(indent)
		fmt.println("\"callee\": {")
		print_expression_ast(e.callee, indent + 1)
		print_indent(indent)
		fmt.println("},")
		print_indent(indent)
		fmt.println("\"arguments\": [")
		for arg, i in e.arguments {
			print_indent(indent + 1)
			fmt.println("{")
			print_expression_ast(arg, indent + 2)
			print_indent(indent + 1)
			if i < len(e.arguments) - 1 {
				fmt.println("},")
			} else {
				fmt.println("}")
			}
		}
		print_indent(indent)
		fmt.print("]")
	
	case ast.TemplateLiteral:
		fmt.println(",")
		print_indent(indent)
		fmt.println("\"quasis\": [ ... ],")
		print_indent(indent)
		fmt.print("\"expressions\": [ ... ]")
	
	case ast.TaggedTemplateExpression:
		fmt.println(",")
		print_indent(indent)
		fmt.println("\"tag\": {")
		print_expression_ast(e.tag, indent + 1)
		print_indent(indent)
		fmt.println("},")
		print_indent(indent)
		fmt.println("\"quasi\": {")
		print_expression_ast(e.quasi, indent + 1)
		print_indent(indent)
		fmt.print("}")
	
	case ast.SpreadElement:
		fmt.println(",")
		print_indent(indent)
		fmt.println("\"argument\": {")
		print_expression_ast(e.argument, indent + 1)
		print_indent(indent)
		fmt.print("}")
	
	case ast.BigIntLiteral:
		fmt.println(",")
		print_indent(indent)
		fmt.printf("\"value\": \"%s\",\n", e.value)
		print_indent(indent)
		fmt.printf("\"raw\": \"%s\"", e.raw)
	
	case ast.RegExpLiteral:
		fmt.println(",")
		print_indent(indent)
		fmt.printf("\"pattern\": \"%s\",\n", e.pattern)
		print_indent(indent)
		fmt.printf("\"flags\": \"%s\"", e.flags)
	
	case ast.UpdateExpression:
		fmt.println(",")
		print_indent(indent)
		op_str := ""
		switch e.operator {
		case .Increment: op_str = "++"
		case .Decrement: op_str = "--"
		}
		fmt.printf("\"operator\": \"%s\",\n", op_str)
		print_indent(indent)
		fmt.printf("\"prefix\": %v,\n", e.prefix)
		print_indent(indent)
		fmt.println("\"argument\": {")
		print_expression_ast(e.argument, indent + 1)
		print_indent(indent)
		fmt.print("}")
	
	case ast.LogicalExpression:
		fmt.println(",")
		print_indent(indent)
		op_str := ""
		#partial switch e.operator {
		case .And: op_str = "&&"
		case .Or:  op_str = "||"
		case .NullishCoalescing: op_str = "??"
		}
		fmt.printf("\"operator\": \"%s\",\n", op_str)
		print_indent(indent)
		fmt.println("\"left\": {")
		print_expression_ast(e.left, indent + 1)
		print_indent(indent)
		fmt.println("},")
		print_indent(indent)
		fmt.println("\"right\": {")
		print_expression_ast(e.right, indent + 1)
		print_indent(indent)
		fmt.print("}")
	
	case ast.SequenceExpression:
		fmt.println(",")
		print_indent(indent)
		fmt.println("\"expressions\": [")
		for expr_elem, i in e.expressions {
			print_indent(indent + 1)
			fmt.println("{")
			print_expression_ast(expr_elem, indent + 2)
			print_indent(indent + 1)
			if i < len(e.expressions) - 1 {
				fmt.println("},")
			} else {
				fmt.println("}")
			}
		}
		print_indent(indent)
		fmt.print("]")
	
	case ast.YieldExpression:
		fmt.println(",")
		print_indent(indent)
		if arg, ok := e.argument.(^ast.Expression); ok && arg != nil {
			fmt.println("\"argument\": {")
			print_expression_ast(arg, indent + 1)
			print_indent(indent)
			fmt.println("},")
		} else {
			fmt.println("\"argument\": null,")
		}
		print_indent(indent)
		fmt.printf("\"delegate\": %v", e.delegate)
	
	case ast.AwaitExpression:
		fmt.println(",")
		print_indent(indent)
		fmt.println("\"argument\": {")
		print_expression_ast(e.argument, indent + 1)
		print_indent(indent)
		fmt.print("}")
	
	case ast.ImportExpression:
		fmt.println(",")
		print_indent(indent)
		fmt.println("\"source\": {")
		print_expression_ast(e.source, indent + 1)
		print_indent(indent)
		fmt.print("}")
	
	case ast.MetaProperty:
		fmt.println(",")
		print_indent(indent)
		fmt.println("\"meta\": {")
		print_indent(indent + 1)
		fmt.printf("\"type\": \"Identifier\",\n")
		print_indent(indent + 1)
		fmt.printf("\"name\": \"import\"\n")
		print_indent(indent)
		fmt.println("},")
		print_indent(indent)
		fmt.println("\"property\": {")
		print_indent(indent + 1)
		fmt.printf("\"type\": \"Identifier\",\n")
		print_indent(indent + 1)
		fmt.printf("\"name\": \"meta\"\n")
		print_indent(indent)
		fmt.print("}")
	
	case ast.PrivateIdentifier:
		fmt.println(",")
		print_indent(indent)
		fmt.printf("\"name\": \"%s\"", e.name)
	
	case ast.ClassExpression:
		fmt.println(",")
		print_indent(indent)
		if e.id != nil {
			id := e.id.(ast.BindingIdentifier)
			fmt.println("\"id\": {")
			print_indent(indent + 1)
			fmt.printf("\"type\": \"Identifier\",\n")
			print_indent(indent + 1)
			fmt.printf("\"name\": \"%s\"\n", id.name)
			print_indent(indent)
			fmt.println("},")
		}
		if super, ok := e.super_class.(^ast.Expression); ok && super != nil {
			fmt.println("\"superClass\": {")
			print_expression_ast(super, indent + 1)
			print_indent(indent)
			fmt.println("},")
		}
		fmt.println("\"body\": { ... }")
	
	case:
		fmt.println(",")
		print_indent(indent)
		fmt.printf("\"[UNIMPLEMENTED]\": true")
	}
}

// ============================================================================
// Type Name Helpers
// ============================================================================

get_statement_type_name :: proc(stmt: ^ast.Statement) -> string {
	if stmt == nil {
		return "nil"
	}
	switch s in stmt^ {
	case ^ast.ExpressionStatement: return "ExpressionStatement"
	case ^ast.EmptyStatement:      return "EmptyStatement"
	case ^ast.BlockStatement:       return "BlockStatement"
	case ^ast.DebuggerStatement:    return "DebuggerStatement"
	case ^ast.ReturnStatement:      return "ReturnStatement"
	case ^ast.BreakStatement:       return "BreakStatement"
	case ^ast.ContinueStatement:    return "ContinueStatement"
	case ^ast.LabeledStatement:     return "LabeledStatement"
	case ^ast.IfStatement:          return "IfStatement"
	case ^ast.SwitchStatement:      return "SwitchStatement"
	case ^ast.WhileStatement:       return "WhileStatement"
	case ^ast.DoWhileStatement:     return "DoWhileStatement"
	case ^ast.ForStatement:         return "ForStatement"
	case ^ast.ForInStatement:       return "ForInStatement"
	case ^ast.ForOfStatement:       return "ForOfStatement"
	case ^ast.WithStatement:        return "WithStatement"
	case ^ast.ThrowStatement:       return "ThrowStatement"
	case ^ast.TryStatement:         return "TryStatement"
	case ^ast.FunctionDeclaration:  return "FunctionDeclaration"
	case ^ast.VariableDeclaration:  return "VariableDeclaration"
	case ^ast.ClassDeclaration:     return "ClassDeclaration"
	case ^ast.ImportDeclaration:    return "ImportDeclaration"
	case ^ast.ExportNamedDeclaration: return "ExportNamedDeclaration"
	case ^ast.ExportDefaultDeclaration: return "ExportDefaultDeclaration"
	case ^ast.ExportAllDeclaration: return "ExportAllDeclaration"
	}
	return "Unknown"
}

get_expression_type_name :: proc(expr: ^ast.Expression) -> string {
	#partial switch e in expr^ {
	case ast.NullLiteral:           return "NullLiteral"
	case ast.BooleanLiteral:        return "BooleanLiteral"
	case ast.NumericLiteral:        return "NumericLiteral"
	case ast.StringLiteral:         return "StringLiteral"
	case ast.BigIntLiteral:         return "BigIntLiteral"
	case ast.RegExpLiteral:         return "RegExpLiteral"
	case ast.TemplateLiteral:       return "TemplateLiteral"
	case ast.TaggedTemplateExpression: return "TaggedTemplateExpression"
	case ast.Identifier:            return "Identifier"
	case ast.ThisExpression:        return "ThisExpression"
	case ast.Super:                 return "Super"
	case ast.ArrayExpression:       return "ArrayExpression"
	case ast.ObjectExpression:      return "ObjectExpression"
	case ast.FunctionExpression:    return "FunctionExpression"
	case ast.ArrowFunctionExpression: return "ArrowFunctionExpression"
	case ast.ClassExpression:       return "ClassExpression"
	case ast.MemberExpression:      return "MemberExpression"
	case ast.CallExpression:        return "CallExpression"
	case ast.NewExpression:         return "NewExpression"
	case ast.ConditionalExpression: return "ConditionalExpression"
	case ast.UpdateExpression:      return "UpdateExpression"
	case ast.UnaryExpression:       return "UnaryExpression"
	case ast.BinaryExpression:      return "BinaryExpression"
	case ast.LogicalExpression:     return "LogicalExpression"
	case ast.AssignmentExpression:  return "AssignmentExpression"
	case ast.SequenceExpression:    return "SequenceExpression"
	case ast.SpreadElement:         return "SpreadElement"
	case ast.YieldExpression:       return "YieldExpression"
	case ast.AwaitExpression:       return "AwaitExpression"
	case ast.ImportExpression:      return "ImportExpression"
	case ast.MetaProperty:          return "MetaProperty"
	}
	return "Unknown"
}

unary_op_to_string :: proc(op: ast.UnaryOperator) -> string {
	switch op {
	case .Minus:        return "-"
	case .Plus:         return "+"
	case .LogicalNot:   return "!"
	case .BitwiseNot:   return "~"
	case .Typeof:       return "typeof"
	case .Void:         return "void"
	case .Delete:       return "delete"
	}
	return "unknown"
}

binary_op_to_string :: proc(op: ast.BinaryOperator) -> string {
	switch op {
	case .Add:                 return "+"
	case .Sub:                 return "-"
	case .Mul:                 return "*"
	case .Div:                 return "/"
	case .Mod:                 return "%"
	case .Pow:                 return "**"
	case .BitOr:               return "|"
	case .BitXor:              return "^"
	case .BitAnd:              return "&"
	case .ShiftLeft:           return "<<"
	case .ShiftRight:          return ">>"
	case .ShiftRightUnsigned:  return ">>>"
	case .Eq:                  return "=="
	case .NotEq:               return "!="
	case .StrictEq:            return "==="
	case .StrictNotEq:         return "!=="
	case .Lt:                  return "<"
	case .Gt:                  return ">"
	case .LtEq:                return "<="
	case .GtEq:                return ">="
	case .Instanceof:          return "instanceof"
	case .In:                  return "in"
	}
	return "unknown"
}

assignment_op_to_string :: proc(op: ast.AssignmentOperator) -> string {
	switch op {
	case .Assign:              return "="
	case .AddAssign:           return "+="
	case .SubAssign:           return "-="
	case .MulAssign:           return "*="
	case .DivAssign:           return "/="
	case .ModAssign:           return "%="
	case .PowAssign:           return "**="
	case .ShiftLeftAssign:     return "<<="
	case .ShiftRightAssign:    return ">>="
	case .ShiftRightUAssign:   return ">>>="
	case .BitOrAssign:         return "|="
	case .BitXorAssign:        return "^="
	case .BitAndAssign:        return "&="
	case .AssignLogicalAnd:    return "&&="
	case .AssignLogicalOr:     return "||="
	case .AssignNullish:       return "??="
	}
	return "unknown"
}

// ============================================================================
// Lex Command (Tokenize)
// ============================================================================

lex_file :: proc(file_path: string) {
	// Read file
	source, read_err := os.read_entire_file_from_path(file_path, context.allocator)
	if read_err != nil {
		fmt.printf("Error: Could not read file: %s\n", file_path)
		os.exit(1)
	}
	defer delete(source, context.allocator)
	
	// Create arena with smart pre-sizing
	arena: mem.Arena
	estimated_size := lexer.estimate_arena_size(len(source))
	backing := make([]byte, estimated_size)
	defer delete(backing, context.allocator)
	mem.arena_init(&arena, backing)
	
	// Initialize optimized lexer
	lex: lexer.LexerAdapter
	lexer.init_adapter(&lex, string(source), &arena)
	
	// Tokenize and print
	fmt.println("[")
	
	token_count := 0
	for {
		tok := lexer.get_current_adapter(&lex)
		
		if tok.type == .EOF {
			break
		}
		
		if token_count > 0 {
			fmt.println(",")
		}
		
		fmt.printf("  {{\"type\": \"%s\", \"value\": ", lexer.get_token_name(tok.type))
		
		// Escape string value for JSON
		escaped := tok.value
		escaped, _ = strings.replace_all(escaped, "\\", "\\\\")
		escaped, _ = strings.replace_all(escaped, "\"", "\\\"")
		escaped, _ = strings.replace_all(escaped, "\n", "\\n")
		escaped, _ = strings.replace_all(escaped, "\t", "\\t")
		escaped, _ = strings.replace_all(escaped, "\r", "\\r")
		fmt.printf("\"%s\", ", escaped)
		fmt.printf("\"loc\": {{\"line\": %d, \"column\": %d}}}", tok.loc.line, tok.loc.column)
		
		token_count += 1
		lexer.next_adapter(&lex)
	}
	
	// Print optimization stats
	stats := lexer.get_stats(&lex)
	fmt.eprintf("\n--- Optimization Stats ---\n")
	fmt.eprintf("Tokens created: %d\n", stats.tokens_created)
	fmt.eprintf("SIMD chunks: %d\n", stats.simd_chunks_processed)
	fmt.eprintf("Scalar fallbacks: %d\n", stats.scalar_fallbacks)
	
	fmt.println()
	fmt.println("]")
	fmt.eprintf("\nTotal tokens: %d\n", token_count)
}

