package kessel

import "core:encoding/json"
import "core:mem"
import "core:strings"

// Conditions use insertion order. Repeated keys replace their original value
// without moving their position, as they do in Node package manifests.
ModuleManifestObject :: struct {
	members: map[string]ModuleManifestValue,
	order: [dynamic]string,
}

ModuleManifestArray :: struct { elements: [dynamic]ModuleManifestValue }
ModuleManifestScalar :: enum { Null, Number }
ModuleManifestValue :: union {
	string,
	bool,
	ModuleManifestScalar,
	^ModuleManifestObject,
	^ModuleManifestArray,
}

@(private)
module_manifest_member :: proc(object: ^ModuleManifestObject, key: string) -> ModuleManifestValue {
	if object == nil { return nil }
	return object.members[key]
}

@(private="file")
ModuleManifestFrame :: struct {
	object: ^ModuleManifestObject,
	array: ^ModuleManifestArray,
	key: string,
}

@(private)
module_manifest_parse :: proc(source: string, allocator: mem.Allocator) -> ModuleManifestValue {
	context.allocator = allocator
	// Raw NUL terminates the tokenizer and it skips vertical tabs and form
	// feeds. JSON disallows all three bytes both inside and outside strings.
	if strings.contains_any(source, "\x00\x0b\x0c") { return nil }
	cursor := json.make_parser(source, .JSON, false, allocator)
	parents := make([dynamic]ModuleManifestFrame, 0, 8, allocator)
	for {
		value, opened := module_manifest_value(&cursor, allocator)
		if value == nil { return nil }
		if opened.object != nil || opened.array != nil {
			if opened.object != nil && !module_manifest_read_key(&cursor, &opened, allocator) { return nil }
			append(&parents, opened)
			continue
		}
		for len(parents) > 0 {
			parent := &parents[len(parents) - 1]
			close := json.Token_Kind.Close_Bracket
			if parent.object != nil {
				if parent.key not_in parent.object.members { append(&parent.object.order, parent.key) }
				parent.object.members[parent.key] = value
				value = parent.object
				close = .Close_Brace
			} else {
				append(&parent.array.elements, value)
				value = parent.array
			}
			if json.allow_token(&cursor, .Comma) {
				if parent.object != nil && !module_manifest_read_key(&cursor, parent, allocator) { return nil }
				break
			}
			if !json.allow_token(&cursor, close) { return nil }
			pop(&parents)
		}
		if len(parents) == 0 {
			if cursor.curr_token.kind != .EOF || cursor.curr_token_err != .EOF { return nil }
			return value
		}
	}
}

@(private="file")
module_manifest_read_key :: proc(cursor: ^json.Parser, frame: ^ModuleManifestFrame, allocator: mem.Allocator) -> bool {
	key, valid := module_manifest_read_string(cursor, allocator)
	if !valid || !json.allow_token(cursor, .Colon) { return false }
	frame.key = key
	return true
}

// Odin also recognizes escaped apostrophes and letters beyond F in Unicode
// escapes. Check the JSON escape alphabet before using the string decoder.
@(private="file")
module_manifest_read_string :: proc(cursor: ^json.Parser, allocator: mem.Allocator) -> (string, bool) {
	token := cursor.curr_token
	if cursor.curr_token_err != nil || token.kind != .String { return "", false }
	body := token.text[1:len(token.text) - 1]
	for len(body) > 0 {
		escape := strings.index_byte(body, '\\')
		if escape < 0 { break }
		body = body[escape + 1:]
		if len(body) == 0 { return "", false }
		switch body[0] {
		case '"', '\\', '/', 'b', 'f', 'n', 'r', 't':
			body = body[1:]
		case 'u':
			if len(body) < 5 { return "", false }
			for digit in transmute([]byte)body[1:5] {
				if !is_hex_digit(digit) { return "", false }
			}
			body = body[5:]
		case: return "", false
		}
	}
	value, err := json.unquote_string(token, .JSON, allocator)
	json.advance_token(cursor)
	return value, err == nil
}

@(private="file")
module_manifest_value :: proc(cursor: ^json.Parser, allocator: mem.Allocator) -> (ModuleManifestValue, ModuleManifestFrame) {
	if cursor.curr_token_err != nil { return nil, {} }
	#partial switch cursor.curr_token.kind {
	case .Open_Brace:
		json.advance_token(cursor)
		object := new(ModuleManifestObject, allocator)
		object.members = make(map[string]ModuleManifestValue, allocator)
		object.order = make([dynamic]string, allocator)
		if json.allow_token(cursor, .Close_Brace) { return object, {} }
		return object, {object = object}
	case .Open_Bracket:
		json.advance_token(cursor)
		array := new(ModuleManifestArray, allocator)
		array.elements = make([dynamic]ModuleManifestValue, allocator)
		if json.allow_token(cursor, .Close_Bracket) { return array, {} }
		return array, {array = array}
	case .String:
		value, valid := module_manifest_read_string(cursor, allocator)
		if !valid { return nil, {} }
		return value, {}
	case .Null:
		json.advance_token(cursor)
		return ModuleManifestScalar.Null, {}
	case .True, .False:
		value := cursor.curr_token.kind == .True
		json.advance_token(cursor)
		return value, {}
	case .Float, .Integer:
		json.advance_token(cursor)
		return ModuleManifestScalar.Number, {}
	}
	return nil, {}
}
