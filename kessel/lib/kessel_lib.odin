package kessel_lib

import "core:c"

// Simple lexer that counts tokens - no Odin string/slice to avoid issues
@(export)
kessel_lex_count :: proc "c" (data: [^]u8, len: c.size_t) -> c.size_t {
    count: c.size_t = 0
    i: c.size_t = 0
    n := len
    
    for i < n {
        c := data[i]
        
        // Whitespace
        if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
            i += 1
            continue
        }
        
        // Identifier
        if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' || c == '$' {
            count += 1
            i += 1
            for i < n {
                c2 := data[i]
                is_id := (c2 >= 'a' && c2 <= 'z') || (c2 >= 'A' && c2 <= 'Z') || 
                         (c2 >= '0' && c2 <= '9') || c2 == '_' || c2 == '$'
                if !is_id { break }
                i += 1
            }
            continue
        }
        
        // Number
        if c >= '0' && c <= '9' {
            count += 1
            i += 1
            for i < n && data[i] >= '0' && data[i] <= '9' {
                i += 1
            }
            continue
        }
        
        // Operators/punctuation
        is_op := c == '+' || c == '-' || c == '*' || c == '/' || c == '=' || 
                 c == '(' || c == ')' || c == '{' || c == '}' || c == '[' || c == ']' ||
                 c == ';' || c == ',' || c == ':' || c == '.' || c == '<' || c == '>'
        if is_op {
            count += 1
        }
        
        i += 1
    }
    
    return count
}

@(export)
kessel_version :: proc "c" () -> cstring {
    return "0.1.0"
}
