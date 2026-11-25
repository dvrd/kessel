package kessel

import "core:strconv"
import "core:strings"

// no-loss-of-precision: a number literal whose digits the stored double
// cannot reproduce. A literal with `n` significant digits is fine when the
// double, written with `n` significant digits, shows the same digits and the
// same exponent (ESLint's rule, as oxlint implements it).

// The digits of a decimal literal in scientific form: `lead.rest × 10^exponent`.
LintDecimal :: struct {
	lead:     u8,
	rest:     string,
	exponent: int,
}

// Fifteen significant decimal digits always survive the trip through a
// double (DBL_DIG) while the value stays well inside the normal range.
LINT_PRECISION_DIGITS_SAFE :: 15
LINT_PRECISION_EXPONENT_SAFE :: 290
LINT_PRECISION_DIGITS_MAX :: 100

lint_check_no_loss_of_precision :: proc(l: ^Linter, e: ^NumericLiteral) {
	if e == nil || !lint_rule_enabled(l, .L2036_NoLossOfPrecision) { return }
	if int(e.loc.end) > len(l.source) || e.loc.start >= e.loc.end { return }
	raw := l.source[e.loc.start:e.loc.end]
	radix := lint_number_radix(raw)
	// Too short to carry more digits than a double holds, unless an exponent
	// moves the value out of range.
	if len(raw) < LINT_PRECISION_DIGITS_SAFE && (radix != 10 || !strings.contains_any(raw, "eE")) { return }
	lossy := lint_decimal_loses_precision(l, raw, e.value) if radix == 10 else
		lint_radix_loses_precision(l, raw, e.value, radix)
	if lossy { lint_emit(l, e.loc, .L2036_NoLossOfPrecision) }
}

lint_number_radix :: proc(raw: string) -> int {
	if len(raw) < 2 || raw[0] != '0' { return 10 }
	switch raw[1] {
	case 'x', 'X': return 16
	case 'b', 'B': return 2
	case 'o', 'O': return 8
	}
	// A legacy octal literal: a leading zero and octal digits only.
	for char in transmute([]u8)raw {
		if char == '_' { continue }
		if char < '0' || char > '7' { return 10 }
	}
	return 8
}

lint_without_separators :: proc(l: ^Linter, raw: string) -> string {
	if !strings.contains_rune(raw, '_') { return raw }
	text, _ := strings.remove_all(raw, "_", l.allocator)
	return text
}

// The literal must end with the value written in its own base.
lint_radix_loses_precision :: proc(l: ^Linter, raw: string, value: f64, radix: int) -> bool {
	text := strings.to_upper(lint_without_separators(l, raw), l.allocator)
	// The reference converts with a saturating cast.
	integer := max(u64) if value >= 18446744073709551615.0 else u64(value)
	buffer: [72]u8
	digits := strconv.write_bits(buffer[:], integer, radix, false, 64, strconv.digits, {})
	return !strings.has_suffix(text, strings.to_upper(digits, l.allocator))
}

// Splits `1.5e3`, `.5`, `0015` into digits and exponent, then moves the
// point after the first significant digit. `float` keeps the trailing zeros
// of an integer as digits, which is how a literal with a point is read.
lint_decimal_normalize :: proc(l: ^Linter, text: string, float: bool) -> (number: LintDecimal, ok: bool) {
	rest := strings.trim_left(text, "0")
	split := 0
	for split < len(rest) && rest[split] >= '0' && rest[split] <= '9' { split += 1 }
	whole := rest[:split] if split > 0 else "0"
	rest = rest[split:]
	fraction := ""
	if len(rest) > 0 && rest[0] == '.' {
		split = 1
		for split < len(rest) && rest[split] >= '0' && rest[split] <= '9' { split += 1 }
		fraction, rest = rest[1:split], rest[split:]
	}
	exponent := 0
	if len(rest) > 0 && (rest[0] == 'e' || rest[0] == 'E') {
		exponent = strconv.parse_int(rest[1:], 10) or_return
	}
	if whole == "0" && len(fraction) > 0 {
		zeros := 0
		for zeros < len(fraction) && fraction[zeros] == '0' { zeros += 1 }
		fraction = fraction[zeros:]
		exponent -= 1 + zeros
		if len(fraction) == 0 { return {'0', "", exponent}, true }
		return {fraction[0], fraction[1:], exponent}, true
	}
	exponent += len(whole) - 1
	if len(whole) == 1 { return {whole[0], fraction, exponent}, true }
	if len(fraction) > 0 {
		return {whole[0], strings.concatenate({whole[1:], fraction}, l.allocator), exponent}, true
	}
	if float { return {whole[0], whole[1:], exponent}, true }
	return {whole[0], strings.trim_right(whole, "0")[1:] if len(strings.trim_right(whole, "0")) > 1 else "", exponent}, true
}

lint_decimal_loses_precision :: proc(l: ^Linter, raw: string, value: f64) -> bool {
	text := lint_without_separators(l, raw)
	mantissa_end := strings.index_any(text, "eE")
	if mantissa_end < 0 { mantissa_end = len(text) }
	float := strings.contains_rune(text[:mantissa_end], '.')
	written, parsed := lint_decimal_normalize(l, text, float)
	// Only an exponent too large to read fails, and no double holds that value.
	if !parsed { return true }
	precision := 1 + len(written.rest)
	if precision > LINT_PRECISION_DIGITS_MAX { return true }
	if precision <= LINT_PRECISION_DIGITS_SAFE && abs(written.exponent) < LINT_PRECISION_EXPONENT_SAFE {
		return false
	}
	stored := lint_double_to_precision(l, value, precision)
	if written.lead != stored.lead || written.rest != stored.rest { return true }
	if written.lead == '0' && written.rest == "" { return false }
	return written.exponent != stored.exponent
}

// A double is an integer times a power of two, so its decimal expansion is
// finite: at most 767 significant digits. LintBigDecimal holds it in limbs of
// nine digits, least significant first.
LINT_BIG_LIMBS :: 96
LINT_BIG_BASE :: 1_000_000_000
LintBigDecimal :: struct {
	limbs: [LINT_BIG_LIMBS]u32,
	count: int,
}

lint_big_multiply :: proc(big: ^LintBigDecimal, factor: u32) {
	carry: u64
	for index in 0..<big.count {
		product := u64(big.limbs[index]) * u64(factor) + carry
		big.limbs[index] = u32(product % LINT_BIG_BASE)
		carry = product / LINT_BIG_BASE
	}
	for carry > 0 {
		assert(big.count < LINT_BIG_LIMBS)
		big.limbs[big.count] = u32(carry % LINT_BIG_BASE)
		carry /= LINT_BIG_BASE
		big.count += 1
	}
}

// The exact decimal digits of a positive finite double, without leading
// zeros, and the decimal exponent of the first digit.
lint_double_digits :: proc(l: ^Linter, value: f64) -> (digits: []u8, exponent: int) {
	assert(value > 0)
	bits := transmute(u64)value
	biased := int((bits >> 52) & 0x7FF)
	assert(biased != 0x7FF)
	mantissa := bits & (1 << 52 - 1)
	power := -1074
	if biased != 0 {
		mantissa |= 1 << 52
		power = biased - 1075
	}
	big: LintBigDecimal
	big.limbs[0] = u32(mantissa % LINT_BIG_BASE)
	big.limbs[1] = u32(mantissa / LINT_BIG_BASE)
	big.count = 2
	// value = mantissa × 2^power. A negative power becomes × 5^n ÷ 10^n.
	base: u32 = 2 if power >= 0 else 5
	step_max := 29 if power >= 0 else 13
	for remaining := abs(power); remaining > 0; {
		step := min(remaining, step_max)
		factor: u32 = 1
		for _ in 0..<step { factor *= base }
		lint_big_multiply(&big, factor)
		remaining -= step
	}
	text := make([dynamic]u8, 0, big.count * 9, l.allocator)
	#reverse for limb, index in big.limbs[:big.count] {
		buffer: [9]u8
		rest := limb
		#reverse for &char in buffer { char = '0' + u8(rest % 10); rest /= 10 }
		skip := 0
		if len(text) == 0 {
			for skip < 9 && buffer[skip] == '0' { skip += 1 }
		}
		append(&text, ..buffer[skip:])
		_ = index
	}
	assert(len(text) > 0)
	exponent = len(text) - 1 + (power if power < 0 else 0)
	return text[:], exponent
}

// Adds one to a run of decimal digits. True when it overflowed to 100…0,
// which the caller accounts for in the exponent.
lint_digits_increment :: proc(digits: []u8) -> bool {
	#reverse for &char in digits {
		if char != '9' { char += 1; return false }
		char = '0'
	}
	digits[0] = '1'
	return true
}

// Number.prototype.toPrecision as the reference computes it: the exact value
// is first rounded half-to-even at a fixed number of fraction digits, then
// rounded half-up to `precision` digits.
lint_double_to_precision :: proc(l: ^Linter, value: f64, precision: int) -> LintDecimal {
	assert(precision >= 1 && precision <= LINT_PRECISION_DIGITS_MAX)
	// Infinity reads back as zero digits, so it never equals a literal.
	if value == 0 || value != value || value - value != 0 { return {'0', "", 0} }
	digits, exponent := lint_double_digits(l, value)
	fraction_digits := 100
	if exponent < 0 { fraction_digits = max(-exponent + precision + 1, 100) }
	kept := exponent + 1 + fraction_digits
	if kept < len(digits) {
		tail := digits[kept:]
		up := tail[0] > '5'
		if tail[0] == '5' {
			up = (digits[kept - 1] - '0') % 2 == 1
			for char in tail[1:] {
				if char != '0' { up = true; break }
			}
		}
		digits = digits[:kept]
		if up && lint_digits_increment(digits) { exponent += 1 }
	}
	out := make([]u8, precision, l.allocator)
	for &char, index in out { char = digits[index] if index < len(digits) else '0' }
	if precision < len(digits) && digits[precision] > '4' {
		if lint_digits_increment(out) { exponent += 1 }
	}
	return {out[0], string(out[1:]), exponent}
}
