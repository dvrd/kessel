package kessel

// What each way of quoting a string literal costs, counted from its source
// spelling. The content is copied as written: only the escapes that exist for
// the sake of the quote change, so the value cannot.
StringQuoting :: struct {
	single_plain, double_plain, tick_plain: int,       // Unescaped quote characters.
	single_escaped, double_escaped, tick_escaped: int, // `\'`, `\"` and "\`".
	newlines: int,       // `\n` escapes, which a template spells as a line break.
	substitutions: int,  // `${`, which a template has to escape.
	template_valid: bool, // No octal or `\8`, `\9` escape, which a template rejects.
}

compress_string_survey :: proc(content: string) -> StringQuoting {
	survey := StringQuoting{template_valid = true}
	for index := 0; index < len(content); index += 1 {
		switch content[index] {
		case '\'': survey.single_plain += 1
		case '"':  survey.double_plain += 1
		case '`':  survey.tick_plain += 1
		case '$':
			if index + 1 < len(content) && content[index+1] == '{' { survey.substitutions += 1 }
		case '\\':
			index += 1
			if index >= len(content) { break }
			switch content[index] {
			case '\'': survey.single_escaped += 1
			case '"':  survey.double_escaped += 1
			case '`':  survey.tick_escaped += 1
			case 'n':  survey.newlines += 1
			case '1'..='9': survey.template_valid = false
			case '0':
				digit := index + 1 < len(content) && content[index+1] >= '0' && content[index+1] <= '9'
				if digit { survey.template_valid = false }
			}
		}
	}
	return survey
}

// The spelling of a string literal with the fewest bytes: the other quote when
// that saves escapes, or a template literal when the string holds line breaks
// or both quotes. Returns "" when the source spelling is already the shortest.
compress_requote :: proc(c: ^MinifyCompressor, raw: string) -> string {
	if len(raw) < 2 || (raw[0] != '\'' && raw[0] != '"') { return "" }
	assert(raw[len(raw)-1] == raw[0])
	content := raw[1:len(raw)-1]
	survey := compress_string_survey(content)
	base := len(content)
	single := base + survey.single_plain - survey.double_escaped - survey.tick_escaped
	double := base + survey.double_plain - survey.single_escaped - survey.tick_escaped
	tick := base + survey.tick_plain + survey.substitutions - survey.single_escaped -
		survey.double_escaped - survey.newlines
	// The source quote wins a tie, then the other quote, then the template.
	quote, size := raw[0], (single if raw[0] == '\'' else double)
	other, other_size := u8('"'), double
	if raw[0] == '"' { other, other_size = '\'', single }
	if other_size < size { quote, size = other, other_size }
	if c.templates && survey.template_valid && tick < size { quote, size = '`', tick }
	if quote == raw[0] && size == base { return "" }
	assert(size < base || quote == raw[0])
	output := make([]byte, size + 2, c.alloc)
	output[0] = quote
	write := 1
	for index := 0; index < len(content); index += 1 {
		char := content[index]
		if char == '\\' && index + 1 < len(content) {
			index += 1
			next := content[index]
			is_quote := next == '\'' || next == '"' || next == '`'
			if next == 'n' && quote == '`' {
				output[write] = '\n'
			} else if is_quote && next != quote {
				output[write] = next
			} else {
				output[write], output[write+1] = '\\', next
				write += 1
			}
		} else {
			escape := char == quote
			escape ||= quote == '`' && char == '$' && index + 1 < len(content) && content[index+1] == '{'
			if escape { output[write] = '\\'; write += 1 }
			output[write] = char
		}
		write += 1
	}
	assert(write == size + 1)
	output[write] = quote
	return string(output)
}
