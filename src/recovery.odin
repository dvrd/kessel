package kessel

import "core:fmt"
import "core:strings"

PARSER_RECOVERY_STUCK_TOKEN_LIMIT :: 100

recovery_eat :: #force_inline proc(p: ^Parser) {
	if p == nil || is_token(p, .EOF) { return }
	p.profile.recovery_tokens_eaten += 1
	eat(p)
}

recovery_is_statement_sync_token :: #force_inline proc(p: ^Parser) -> bool {
	return is_token(p, .Semi) || is_token(p, .RBrace)
}

recovery_should_report_unexpected :: proc(p: ^Parser) -> bool {
	if p == nil { return false }
	if len(p.errors) > 0 && p.errors[len(p.errors)-1].start == cur_offset(p) {
		return false
	}
	if p.cur_type == .RParen || p.cur_type == .RBracket {
		return false
	}
	return true
}

recovery_should_report_unexpected_top_level :: proc(p: ^Parser) -> bool {
	if !recovery_should_report_unexpected(p) { return false }
	if p.cur_type == .Invalid && p.lexer != nil &&
	   int(p.lexer.cur.start) < len(p.lexer.source_bytes) {
		b := p.lexer.source_bytes[p.lexer.cur.start]
		if b >= 0x80 || (b < 0x20 && b != '\n' && b != '\r' && b != '\t') {
			return false
		}
	}
	return true
}

recovery_report_unexpected_token :: proc(p: ^Parser) {
	if !recovery_should_report_unexpected(p) { return }
	msg := fmt.tprintf("Unexpected token '%s'", cur_value(p))
	report_error_coded(p, .K2040_UnexpectedToken, msg)
}

recovery_report_unexpected_token_top_level :: proc(p: ^Parser) {
	if !recovery_should_report_unexpected_top_level(p) { return }
	msg := fmt.tprintf("Unexpected token '%s'", cur_value(p))
	report_error_coded(p, .K2040_UnexpectedToken, msg)
}

recovery_raw_has_escape :: #force_inline proc(raw: string) -> bool {
	return strings.contains(raw, "\\")
}
