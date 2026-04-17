package lexer

// Test mínimo del lexer
import "core:fmt"
import "core:mem"

test_lexer :: proc() {
	source := "const x = 1;"
	
	// Create arena
	arena: mem.Arena
	backing := make([]byte, 64 * 1024)
	mem.arena_init(&arena, backing)
	
	// Initialize lexer
	l: Lexer2
	init_lexer2(&l, source, &arena)
	
	// Print first 10 tokens
	fmt.println("=== Test Lexer ===")
	fmt.printf("Source: '%s'\n\n", source)
	
	for i := 0; i < 10; i += 1 {
		tok := get_current2(&l)
		view := get_token_view(tok)
		
		if view.token_type == .EOF {
			fmt.println("EOF")
			break
		}
		
		text := get_token_source(tok, source)
		fmt.printf("Token %d: type=%v text='%s' offset=%d length=%d\n", 
			i, view.token_type, text, view.offset, view.length)
		
		next2(&l)
	}
}
