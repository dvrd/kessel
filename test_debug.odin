package main

import "core:fmt"
import "core:os"
import "core:mem"

import lexer "./kessel/src/lexer"
import parser "./kessel/src/parser"
import ast "./kessel/src/ast"

main :: proc() {
	source := `const var0 = { n: 0, f: () => 0 * 2 };`
	
	arena: mem.Arena
	backing := make([]byte, 64 * 1024)
	defer delete(backing)
	mem.arena_init(&arena, backing)
	
	lex: lexer.LexerAdapter
	lexer.init_adapter(&lex, source, &arena)
	
	// Test lexing
	fmt.println("=== Lexer Test ===")
	token_count := 0
	for {
		tok := lexer.get_current_adapter(&lex)
		fmt.printf("Token %d: %v\n", token_count, tok.type)
		token_count += 1
		if tok.type == .EOF || tok.type == .Invalid {
			break
		}
		if token_count > 50 {
			fmt.println("Too many tokens, breaking")
			break
		}
		lexer.next_adapter(&lex)
	}
	
	fmt.println("\n=== Parser Test ===")
	// Reset arena
	mem.arena_init(&arena, backing)
	lexer.init_adapter(&lex, source, &arena)
	
	p: parser.Parser
	parser.init_parser_adapter(&p, &lex, &arena)
	
	program := parser.parse_program(&p, .Script)
	
	fmt.printf("Parsed %d statements\n", len(program.body))
	fmt.printf("Errors: %d\n", len(p.errors))
	for err in p.errors {
		fmt.printf("  Error at line %d: %s\n", err.loc.line, err.message)
	}
}
