'use strict';

// Inputs and documented deviations for verify_regex_ast_reference.js.
//
// `grammarPatterns` walks the ES2025 pattern grammar area by area, valid and
// invalid, so the gate covers forms the corpora rarely contain (modifiers,
// duplicate named groups, `v`-mode set notation, Annex B leftovers). The
// patterns are given to the constructor oracle, so some hold an unescaped `/`
// or a line terminator that a source literal could not.

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const R = String.raw;

// Each row: flags, then the patterns to try with those flags.
const grammarRows = [
  // Modifiers.
  ['', ['(?i:a)', '(?m:^a$)', '(?s:.)', '(?ims:a)', '(?-i:a)', '(?-ims:a)', '(?i-m:a)',
    '(?im-s:a)', '(?s-im:a)', '(?i-:a)', '(?-:a)', '(?:a)', '(?i:)', '(?i:a|b)|c',
    '(?i:(?-i:a)b)', '(?ii:a)', '(?i-i:a)', '(?-ii:a)', '(?a:b)', '(?I:a)', '(?i-M:a)',
    '(?i', '(?i-', '(?i-s', '(?i)', '(?-i)', '(?i:a', '(?i-m-s:a)', '(?ims-ims:a)', '(?u:a)',
    '(?i:a){2}', '(?i:a)+?', '(?msi:a)', '(?i :a)', '(?:)', '(?i::)']],
  ['u', ['(?i:a)', '(?-s:.)', '(?i-m:\\p{Lu})', '(?ii:a)', '(?-:a)']],
  ['v', ['(?i:[a--b])', '(?m-i:[\\q{ab}])', '(?s-s:a)']],
  // Groups, names, duplicate names (ES2025), references.
  ['', ['(a)', '(?<a>b)', '(?<a>b)|(?<a>c)', '(?<a>b)(?<a>c)', '(?:(?<a>x)|(?<a>y))\\k<a>',
    '(?<a>x)|(?:(?<a>y)|(?<a>z))', '(?<a>x)(?:(?<a>y)|(?<a>z))', '((?<a>x)|(?<b>y))|(?<a>z)',
    '(?<a>(?<a>x))', '(?<a>x)|(?<b>y)(?<a>z)', '(?<a>x)|(?<a>y)|(?<a>z)', '(?<$>a)', '(?<_a1>a)',
    R`(?<\u0061>a)\k<a>`, R`(?<\u{61}>a)\k<a>`, R`(?<a>a)\k<\u0061>`, '(?<π>a)\\k<π>',
    R`(?<\ud835\udc9c>a)`, R`(?<\u{1d49c}>a)`, '(?<𝒜>a)\\k<𝒜>', '(?<1a>a)', '(?<a-b>a)', '(?<>a)',
    '(?<a', '(?<a>', '(?<a>a', '(?<a>a)\\k<b>', '(?<a>a)\\k', '(?<a>a)\\k<', '(?<a>a)\\k<a',
    '\\k<a>(?<a>a)', '\\k<a>', '\\k', '\\k<', '\\k<a', '\\k<>', '\\ka', '\\k{a}', '[\\k]',
    '[\\k<a>](?<a>a)', '(?<a>a)[\\k<a>]', '(a)\\1', '\\1(a)', '\\2(a)', '(a)\\2', '\\1', '\\8',
    '\\9', '\\10', '(a)(b)(c)(d)(e)(f)(g)(h)(i)(j)\\10', '(a)(b)(c)(d)(e)(f)(g)(h)(i)(j)\\11',
    '(a)\\18', '(a)\\01', '(a)\\1\\0', '[\\1](a)', '()', '(|)', '(a|)', '(|a)', '(', ')', '(?',
    '(?)', '(?x)', '((a)|(b))\\2\\3', '(?:a)(b)(?=c)(d)(?<e>f)\\3', '(?<a>.)\\k<a>(?<b>.)\\k<b>',
    '(?<__proto__>a)', '(?<a>a)(?<A>b)', '(?<a\\>a)', '(?<\\>a)', '(?<a b>c)']],
  ['u', ['(?<a>b)|(?<a>c)', '(?<a>b)(?<a>c)', '\\k<a>', '(?<a>a)\\k<b>', '(?<a>a)\\k<a>', '\\k',
    '(a)\\2', '\\1(a)', '\\1', '(a)\\10', '(a)\\01', R`(?<\ud835\udc9c>a)`, R`(?<\u{1d49c}>a)`,
    '(?<𝒜>a)\\k<𝒜>', R`(?<\ud835>a)`, R`(?<\u{110000}>a)`, '[\\k<a>](?<a>a)', '[\\1](a)']],
  // Lookaround.
  ['', ['(?=a)', '(?!a)', '(?<=a)', '(?<!a)', '(?=a)*', '(?!a)+', '(?=a){2}', '(?=a)?b',
    '(?<=a)*', '(?<!a)+', '(?<=a){1}', '(?<=a)?', '(?<=(a))\\1', '(?<=\\1(a))',
    '(?<!(?<n>a))\\k<n>',
    '(?=', '(?!', '(?<=', '(?<!', '(?<=a', '(?=(?<=a)b)', '(?<=a|b)c', '(?<!a|b)c', '^*', '$+',
    '\\b*', '\\B?', '^{1}', '$?', '(?=a)|(?!b)|(?<=c)|(?<!d)', '(?<=)', '(?<!)']],
  ['u', ['(?=a)*', '(?!a)+', '(?=a){2}', '(?<=a)*', '(?<=a)b', '(?<!a)b', '(?=a)b', '^*', '\\b+']],
  ['v', ['(?=a)*', '(?<=a)+', '(?<=[a--b])c']],
  // Quantifiers and braces.
  ['', ['a*', 'a+', 'a?', 'a*?', 'a+?', 'a??', 'a{1}', 'a{1,}', 'a{1,2}', 'a{1}?', 'a{1,}?',
    'a{1,2}?', 'a{0}', 'a{0,0}', 'a{2,1}', 'a{01,002}', 'a{', 'a{1', 'a{1,', 'a{1,2', 'a{,2}',
    'a{,}', 'a{}', 'a{a}', 'a{1,a}', 'a{ 1}', 'a{1 }', 'a{1, 2}', '{', '}', '{}', '{1}', '{1,2}',
    'a|{1}', '({1})', '(?:{1})', 'a**', 'a++', 'a???', 'a{1}{2}', 'a{1}*', 'a*{1}', '*', '+',
    '?', '|*', '(*)', '(?:+)', 'a|+', 'x{9007199254740991}', 'x{9007199254740992}',
    'x{99999999999999999999999}', 'x{99999999999999999999999,}',
    'x{99999999999999999999999,99999999999999999999998}', 'x{2,99999999999999999999999}',
    'x{18446744073709551615}', 'x{18446744073709551616}',
    'x{18446744073709551616,18446744073709551615}', 'a{1}b{2,}c{3,4}?d', 'a]', ']', 'a}',
    '{a', 'a{b', '{1}a', 'a{1,2}{', 'a{{1}', '(a{)', '[{]', '[}]', 'a{1}}', '\\{', '\\}',
    'a{,', 'a{1,2,3}', '.*?', '.+?x', '[a]{2}', '(a){2}', '\\d{2,}', '\\1{2}(a)', '(?:a){0}']],
  ['u', ['a{', 'a{1', 'a{1,', 'a{,2}', 'a{}', '{', '}', ']', 'a]', 'a}', '{1}', 'a{1}', 'a{2,1}',
    'a{1,2}?', '\\{', '\\}', '\\]', 'a**', 'x{9007199254740992}', 'a{b']],
  ['v', ['a{', '}', ']', 'a{1,2}', '\\}']],
  // Atoms, escapes, Annex B identity escapes.
  ['', ['(?i:a)\\1', '(?i:a)(b)\\1', '\\400{2}', '[\\400-\\777]', '[\\40-\\400]', '\\377{2}']],
  ['u', ['(?i:a)\\1', '(?i:a)(b)\\1']],
  ['', ['a', '.', '\\.', '\\/', '/', 'a/b', '[/]', '^$', '\\b\\B', '\\d\\D\\s\\S\\w\\W',
    '\\t\\n\\v\\f\\r',
    '\\0', '\\00', '\\000', '\\0000', '\\01', '\\07', '\\08', '\\09', '\\1', '\\7', '\\8', '\\12',
    '\\77', '\\78', '\\123', '\\377', '\\378', '\\400', '\\477', '\\777', '\\1234', '\\0a',
    '[\\0]', '[\\00]', '[\\01]', '[\\08]', '[\\1]', '[\\8]', '[\\12]', '[\\377]', '[\\400]',
    '[\\777]', '[\\1-\\3]', '[\\0-\\10]', '\\cA', '\\ca', '\\cZ', '\\cz', '\\c', '\\c1', '\\c_',
    '\\c*', '\\c+', '\\c?', '\\c{2}', '\\c|a', '(\\c)', '\\c\\c', '\\c$', '[\\c]', '[\\cA]',
    '[\\ca]', '[\\c1]', '[\\c9]', '[\\c_]', '[\\c-]', '[\\c*]', '[\\c-a]', '[\\c0-\\c9]',
    '[a-\\c]', '[\\c-\\c]', '[\\c', '[\\cé]', '\\cé', '\\x', '\\x4', '\\x41', '\\x4g', '\\xZZ',
    '\\x414', '[\\x]', '[\\x41]', '[\\x4]', '[\\x40-\\x42]', '\\u', '\\u0', '\\u00', '\\u004',
    '\\u0041', '\\u00411', '\\uD83D\\uDE00', '\\uDE00\\uD83D', '\\uD83D', '\\u{', '\\u{}',
    '\\u{41}', '\\u{1F600}', '\\u{110000}', '\\u{41', '[\\u]', '[\\u0041]', '[\\u{41}]',
    '[\\uD83D\\uDE00]', '[\\u0041-\\u0043]', '\\a', '\\e', '\\g', '\\h', '\\i', '\\j', '\\l',
    '\\m', '\\o', '\\q', '\\y', '\\z', '\\A', '\\E', '\\Z', '\\_', '\\-', '\\ ', '\\é', '\\😀',
    '\\$', '\\^', '\\*', '\\+', '\\?', '\\(', '\\)', '\\[', '\\]', '\\{', '\\}', '\\|', '\\\\',
    '\\', 'a\\', '[\\', '[\\]', '\\p', '\\P', '\\p{', '\\p{L}', '\\P{L}', '\\p{L', '\\pL',
    '[\\p{L}]', '[\\P{L}]', '[\\p]', '[a-\\p]', '\\p{Script=Greek}', '\\p*', '\\p{L}+',
    '😀', '😀*', '😀{2}', '[😀]', '[😀-😁]', '[a-😀]', 'é', 'é+', '\u2028', 'a\nb', 'a\rb',
    '\\\n', '[\n]', '\\\u2028', 'a\u2029', '\t', ' ', 'a b', '\\b+', '[\\b]', '[\\B]', '[\\b-a]',
    '[\\-]', '[\\d-a]', '[a-\\d]', '[\\d-\\w]', '[\\s-z]', '[--a]', '[a--]', '[---]', '[+--]',
    '[a-]', '[-a]', '[-]', '[]', '[^]', '[^a]', '[^-]', '[^^]', '[a^]', '[]a]', '[^]a]',
    '[a-z]', '[z-a]', '[a-a]', '[a-b-c]', '[a-b-c-d]', '[\\]]', '[[]', '[[]]', '[a[b]c]', '[',
    '[a', '[a-', '[^', '[]]', '[\\w-]', '[-\\w]', '[\\w-\\d]', '[a-z0-9_$]', '[&&]', '[a&&b]',
    '[a--b]', '[\\q{a}]', '[(]', '[)]', '[|]', '[.]', '[*]', '[\\^]', '[$]', '[\\S\\s]',
    '[^\\S\\s]', '[\\u{1F600}]', '[\\cJ]', '[\\ud83d\\ude00-\\ud83d\\ude0f]']],
  ['i', ['a', '[a-z]', '\\u017F', '(?-i:a)']],
  ['s', ['.', '(?-s:.)']],
  ['m', ['^a$', '(?-m:^)']],
  ['y', ['a']], ['d', ['(a)']], ['g', ['a']], ['dgimsy', ['(?<a>.)']], ['dgimsuy', ['.']],
  ['dgimsvy', ['.']], ['uv', ['a']], ['gg', ['a']], ['x', ['a']], ['U', ['a']], ['gimsuyd', ['a']],
  ['u', ['a', '\\/', '/', '\\0', '\\00', '\\01', '\\1', '\\8', '\\cA', '\\ca', '\\c', '\\c1',
    '\\c_',
    '[\\c]', '[\\cA]', '[\\c1]', '[\\c_]', '\\x', '\\x4', '\\x41', '[\\x]', '\\u', '\\u0041',
    '\\u004', '\\uD83D\\uDE00', '\\uDE00\\uD83D', '\\uD83D', '\\uD83D\\u0041', '\\uD83D\\uDE0',
    '\\u{', '\\u{}', '\\u{41}', '\\u{0041}', '\\u{000041}', '\\u{1F600}', '\\u{10FFFF}',
    '\\u{110000}', '\\u{41', '\\u{4G}', '[\\u{41}]', '[\\uD83D\\uDE00]', '[\\u{1F600}-\\u{1F64F}]',
    '[\\uD83D\\uDE00-\\uD83D\\uDE4F]', '[\\uDE00-\\uD83D]', '\\uD83D\\uDE00+', '(?:\\uD83D)\\uDE00',
    '\\a', '\\e', '\\-', '\\ ', '\\_', '\\é', '\\$', '\\^', '\\*', '\\+', '\\?', '\\(', '\\)',
    '\\[', '\\]', '\\{', '\\}', '\\|', '\\\\', '\\.', '\\', '[\\-]', '[\\a]', '[\\b]', '[\\B]',
    '[\\$]', '[\\^]', '[\\]]', '[\\d-a]', '[a-\\d]', '[\\d-\\w]', '[\\p{L}-a]', '[a-\\p{L}]',
    '[--a]', '[a--]', '[a-]', '[-a]', '[-]', '[]', '[^]', '[]a]', '[z-a]', '[a-b-c]', '[[]',
    '[a[b]c]', '[&&]', '[a&&b]', '[\\q{a}]', '[\\0]', '[\\00]', '[\\1]', '😀', '😀*', '😀{2}',
    '[😀]', '[😀-😁]', '[😁-😀]', '[a-😀]', '\\😀', '\\p', '\\p{', '\\p{}', '\\p{L}', '\\P{L}',
    '\\p{L', '\\pL', '\\p{Lu}', '\\p{Letter}', '\\p{General_Category=Letter}', '\\p{gc=L}',
    '\\p{General_Category}', '\\p{gc}', '\\p{Script=Greek}', '\\p{sc=Grek}', '\\p{Script}',
    '\\p{Script_Extensions=Latin}', '\\p{scx=Latn}', '\\p{Script=}', '\\p{=Greek}',
    '\\p{Script=Greek=x}', '\\p{Script=NotAScript}', '\\p{NotAProperty}', '\\p{ASCII}',
    '\\P{ASCII}', '\\p{Any}', '\\p{Assigned}', '\\p{ASCII_Hex_Digit}', '\\p{AHex}',
    '\\p{Alphabetic}',
    '\\p{Emoji}', '\\p{Emoji_Presentation}', '\\p{ID_Start}', '\\p{XID_Continue}',
    '\\p{White_Space}',
    '\\p{space}', '\\p{ascii}', '\\p{ ASCII}', '\\p{ASCII }', '\\p{L}+', '\\p{L}{2}', '[\\p{L}]',
    '[^\\p{L}]', '[\\P{L}\\p{N}]', '[\\p{L}-\\p{N}]', '[\\p{L}a-z]', '\\p{Basic_Emoji}',
    '\\p{RGI_Emoji}', '\\p{Emoji_Keycap_Sequence}', '\\P{Basic_Emoji}', '\\p{Lowercase_Letter}',
    '\\p{Ll}', '\\p{lc}', '\\p{LC}', '\\p{Cased_Letter}', '\\p{Other}', '\\p{C}', '\\p{Cn}',
    '\\p{Block=Basic_Latin}', '\\p{InBasicLatin}', '\\p{IsLatin}', '\\p{Line_Break=Alphabetic}',
    '\\p{Script=Latin}\\P{Script=Greek}', '.', '^$', '\\b\\B', '\\d\\D\\s\\S\\w\\W', '\u2028',
    'a\nb', '[\n]']],
  // `v`-mode set notation.
  ['v', ['[a]', '[ab]', '[a-z]', '[^a-z]', '[]', '[^]', '[[]]', '[[a]]', '[[a][b]]', '[a[b]c]',
    '[[a-z][0-9]]', '[^[a-z]]', '[[^a-z]]', '[[[[a]]]]', '[a&&b]', '[a&&b&&c]', '[a--b]',
    '[a--b--c]', '[[a-z]&&[aeiou]]', '[[a-z]--[aeiou]]', '[^[a-z]--[aeiou]]',
    '[\\p{L}&&\\p{ASCII}]',
    '[\\p{L}--\\p{Lu}]', '[\\w--\\d]', '[\\w&&\\d]', '[\\d--[0-4]]', '[[a-z]&&\\p{L}&&[^x]]',
    '[a&&b--c]', '[a--b&&c]', '[a&&]', '[&&a]', '[a--]', '[--a]', '[a&&&b]', '[a&&&&b]',
    '[a---b]', '[a-z&&b]', '[a&&b-z]', '[a-z--b]', '[a&b]', '[a&]', '[&]', '[&&]', '[--]',
    '[a-]', '[-a]', '[-]', '[a-b-c]', '[a b]', '[ab&&c]', '[a&&bc]', '[[ab]&&c]', '[a&&[bc]]',
    '[a--bc]', '[ab--c]', '[\\q{}]', '[\\q{a}]', '[\\q{ab}]', '[\\q{a|b}]', '[\\q{ab|cd|e}]',
    '[\\q{|}]', '[\\q{a|}]', '[\\q{|a}]', '[\\q{||}]', '[\\q{a\\|b}]', '[\\q{\\}}]', '[\\q{\\\\}]',
    '[\\q{\\u{1F600}}]', '[\\q{\\u0041b}]', '[\\q{\\n}]', '[\\q{\\b}]', '[\\q{\\cA}]', '[\\q{\\0}]',
    '[\\q{\\x41}]', '[\\q{😀}]', '[\\q{😀😁|é}]', '[\\q{a-b}]', '[\\q{\\-}]', '[\\q{(}]',
    '[\\q{[}]', '[\\q{]}]', '[\\q{{}]', '[\\q{/}]', '[\\q{a&&b}]', '[\\q{&}]', '[\\q{\\&}]',
    '[\\q{\\d}]', '[\\q{\\p{L}}]', '[\\q{\\1}]', '[\\q{\\a}]', '[\\q{\\k}]', '[\\q{]', '[\\q{a]',
    '[\\q]', '[\\qa]', '[\\q{a}\\q{b}]', '[\\q{ab}--\\q{ab}]', '[\\q{ab}&&\\q{ab}]',
    '[\\q{ab}&&a]', '[a&&\\q{ab}]', '[a--\\q{ab}]', '[\\q{ab}--a]', '[^\\q{a}]', '[^\\q{ab}]',
    '[^\\q{a|b}]', '[^\\q{}]', '[^\\q{a|}]', '[^[\\q{ab}]]', '[[^\\q{ab}]]', '[^\\q{ab}&&a]',
    '[^a&&\\q{ab}]', '[^\\q{ab}&&\\q{ab}]', '[^\\q{ab}--a]', '[^a--\\q{ab}]', '[^\\q{ab}a]',
    '[\\q{ab}-z]', '[a-\\q{z}]', '\\q{a}', '\\q', '[\\p{RGI_Emoji}]', '[^\\p{RGI_Emoji}]',
    '\\p{RGI_Emoji}', '\\P{RGI_Emoji}', '[\\P{RGI_Emoji}]', '[\\p{RGI_Emoji}--\\q{a}]',
    '[\\p{RGI_Emoji}&&\\p{Emoji}]', '[^\\p{RGI_Emoji}&&\\p{Emoji}]',
    '[^\\p{Emoji}&&\\p{RGI_Emoji}]',
    '[^\\p{RGI_Emoji}--\\p{Emoji}]', '[^\\p{Emoji}--\\p{RGI_Emoji}]', '[\\p{Basic_Emoji}a]',
    '[^\\p{Basic_Emoji}a]', '\\p{RGI_Emoji_Flag_Sequence}', '\\p{RGI_Emoji_Tag_Sequence}',
    '\\p{RGI_Emoji_Modifier_Sequence}', '\\p{RGI_Emoji_ZWJ_Sequence}', '\\p{Emoji_Keycap_Sequence}',
    '\\p{Basic_Emoji}+', '[\\p{L}]', '[\\p{L}\\p{N}]', '[\\p{L}-a]', '[(]', '[)]', '[{]', '[}]',
    '[/]', '[|]', '[\\(]', '[\\)]', '[\\[]', '[\\]]', '[\\{]', '[\\}]', '[\\/]', '[\\-]', '[\\|]',
    '[\\&]', '[\\!]', '[\\#]', '[\\%]', '[\\,]', '[\\:]', '[\\;]', '[\\<]', '[\\=]', '[\\>]',
    '[\\@]', '[\\`]', '[\\~]', '[\\_]', '[\\a]', '[\\$]', '[\\^]', '[\\*]', '[\\+]', '[\\.]',
    '[\\?]', '[\\\\]', '[!]', '[#]', '[%]', '[,]', '[:]', '[;]', '[<]', '[=]', '[>]', '[@]',
    '[`]', '[~]', '[_]', '[$]', '[^^]', '[a^]', '[*]', '[+]', '[.]', '[?]', '[!!]', '[##]',
    '[$$]', '[%%]', '[**]', '[++]', '[,,]', '[..]', '[::]', '[;;]', '[<<]', '[==]', '[>>]',
    '[??]', '[@@]', '[^^^]', '[``]', '[~~]', '[a!!b]', '[!-#]', '[a-z!]', '[\\b]', '[\\B]',
    '[\\cA]', '[\\c]', '[\\c1]', '[\\0]', '[\\00]', '[\\1]', '[\\x41]', '[\\u{41}]', '[\\u0041]',
    '[\\uD83D\\uDE00]', '[😀]', '[😀-😁]', '[😀&&😀]', '[\\d]', '[\\D\\S\\W]', '[\\d-a]',
    '[a-\\d]', '[\\n-\\r]', '[\\t\\n\\v\\f\\r]', '[a-z&&[^aeiou]]', '[[a-z]--[aeiou]--[xyz]]',
    '[[a-z]&&[a-m]&&[c-z]]', '[[[a-z]--[aeiou]]&&[b-d]]', '[\\q{abc}a-z[0-9]\\p{Lu}]', '[',
    '[[', '[[]', '[[a]', '[a]]', ']', '[]]', '[a', '[\\', 'a', '.', '\\/', '/', '{', '}', 'a{',
    '(?<a>[\\q{ab}])\\k<a>', '[\\q{ab}]+', '[\\q{ab}]{2}', '[a-z]--[b]', 'a&&b', '\\-', '\\&',
    '[\\q{a}&&\\q{a}&&\\q{a}]', '[\\q{ab}--\\q{ab}--\\q{ab}]', '[^[^\\q{ab}]]',
    '[[\\q{ab}]--[\\q{ab}]]',
    '[^[\\q{ab}]--[\\q{ab}]]', '[^[\\q{ab}]&&[a]]', '[^[a]&&[\\q{ab}]]', '[^[\\q{ab}]&&[\\q{ab}]]',
    '[^[\\q{a}]&&[\\q{ab}]]', '[^\\q{a|b}&&\\q{ab}]', '[\\--a]', '[a\\-]', '[\\-\\-]', '[a&&\\&]',
    '[\\&&&a]', '[a\\&&b]', '[&a]', '[a&&b&c]', '[\\q{a}b&&c]']],
];

const grammarPatterns = [];
for (const [flags, patterns] of grammarRows) {
  for (const pattern of patterns) grammarPatterns.push({ pattern, flags, origin: 'constructor' });
}

const key = (pattern, flags) => JSON.stringify([pattern, flags]);

// Accept/reject differences from Node that are deliberate. Every entry carries
// the reason Kessel is right; an entry that stops deviating fails the gate.
//
// ECMA-262 22.2.1.1: "It is a Syntax Error if the MV of the first DecimalDigits
// is strictly greater than the MV of the second DecimalDigits." V8 clamps each
// bound to a 31-bit maximum before comparing, so two huge bounds compare equal
// and the pattern compiles. Kessel compares the digit strings exactly.
const clampedBounds = 'minimum exceeds maximum; V8 clamps both bounds before comparing them';
const nodeDeviations = new Map([
  [key('x{99999999999999999999999,99999999999999999999998}', ''), clampedBounds],
  [key('x{18446744073709551616,18446744073709551615}', ''), clampedBounds],
]);

// Unicode version of the tables in src/regex_ast_properties.odin. A Node built
// on an older Unicode rejects the newest names; the gate reports those.
const TABLE_UNICODE_VERSION = '18.0';

function odinStringTable(source, name) {
  const table = new RegExp(`${name} := \\[\\?\\]string\\{([\\s\\S]*?)\\n\\}`).exec(source);
  assert.ok(table, `Missing table ${name}`);
  const body = table[1].replace(/\/\/.*$/gm, '');
  const names = [...body.matchAll(/"([^"]+)"/g)].map(found => found[1]);
  assert.ok(names.length > 0, `Empty table ${name}`);
  return names;
}

// Every property name or value Kessel knows, strictly or leniently, plus near
// misses, each tried as a lone name and as a value of the three properties
// that take one. This replays the strict tables against Node entry by entry
// and proves that the names only the lenient parser tables hold are rejected.
function propertyPatterns(repository) {
  const strict = fs.readFileSync(path.join(repository, 'src/regex_ast_properties.odin'), 'utf8');
  const lenient = fs.readFileSync(path.join(repository, 'src/regex.odin'), 'utf8');
  const names = new Set([
    ...odinStringTable(strict, 'REGEX_AST_BINARY_PROPERTIES'),
    ...odinStringTable(strict, 'REGEX_AST_GENERAL_CATEGORIES'),
    ...odinStringTable(strict, 'REGEX_AST_SCRIPTS'),
    ...odinStringTable(lenient, 'BINARY_UNICODE_PROPERTIES'),
    ...odinStringTable(lenient, 'GENERAL_CATEGORY_VALUES'),
    ...odinStringTable(lenient, 'SCRIPT_VALUES'),
    ...odinStringTable(lenient, 'PROPERTIES_OF_STRINGS'),
    'General_Category', 'gc', 'Script', 'sc', 'Script_Extensions', 'scx', 'Block', 'blk',
    'Line_Break', 'Name', 'Age', 'Numeric_Value', 'latin', 'LATIN', 'Latn_', 'ascii', 'Ascii',
    'RGI_Emoji_Sequence', 'Emoji_Sequence', 'Other_Alphabetic', 'InBasicLatin', 'IsLatin',
  ]);
  // Every name shaped like a short General_Category alias.
  const upper = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
  for (const first of upper) {
    names.add(first);
    for (const second of upper + upper.toLowerCase()) names.add(first + second);
  }
  const literals = [];
  for (const name of [...names].sort()) {
    for (const [pattern, flags] of [
      [`\\p{${name}}`, 'u'], [`\\p{${name}}`, 'v'], [`\\P{${name}}`, 'v'], [`[^\\p{${name}}]`, 'v'],
      [`\\p{gc=${name}}`, 'u'], [`\\p{General_Category=${name}}`, 'v'], [`\\p{sc=${name}}`, 'u'],
      [`\\p{Script=${name}}`, 'v'], [`\\p{scx=${name}}`, 'u'],
      [`\\P{Script_Extensions=${name}}`, 'u'], [`\\p{${name}=${name}}`, 'u'],
    ]) {
      literals.push({ pattern, flags, origin: 'constructor' });
    }
  }
  return literals;
}

// Fragments for generatedPatterns: every construct of the grammar plus the
// pieces that make patterns invalid, so random concatenation lands on both
// sides of each rule.
const fragments = [
  'a', 'b', 'c', 'z', '0', '1', '8', '_', ' ', 'é', '😀', '-', '^', '$', '.', ',', '/', '<', '>',
  '=', ':', '!', '&', '*', '+', '?', '??', '{', '}', '{1}', '{1,}', '{1,2}', '{2,1}', '{,2}',
  '(', ')', '(?:', '(?=', '(?!', '(?<=', '(?<!', '(?<a>', '(?<b>', '(?<π>', '(?<\\u0061>',
  '(?i:', '(?-i:', '(?i-m:', '(?s-s:', '(a)', '[', '[^', ']', '[a-z]', '[[', ']]', '|', '\\',
  '\\b', '\\B', '\\d', '\\w', '\\S', '\\n', '\\k', '\\k<a>', '\\k<b>', '\\k<π>', '\\1', '\\2',
  '\\0', '\\00', '\\07', '\\37', '\\400', '\\8', '\\c', '\\cA', '\\c1', '\\c_', '\\x', '\\x41',
  '\\x4', '\\u', '\\u0041', '\\uD83D', '\\uDE00', '\\u{41}', '\\u{1F600}', '\\u{110000}',
  '\\p', '\\p{L}', '\\P{L}', '\\p{Lu}', '\\p{Script=Greek}', '\\p{sc=Grek}', '\\p{sc=Nope}',
  '\\p{RGI_Emoji}', '\\P{RGI_Emoji}', '\\q', '\\q{', '\\q{ab}', '\\q{a|b}', '\\q{😀|}', '&&',
  '&&&', '--', '!!', '\\/', '\\-', '\\&', '\\.', '\\$', '\\a',
];

// A fixed pseudo-random sample of fragment concatenations. The seed is part of
// the gate: the same patterns are generated on every run and every machine.
function generatedPatterns(count) {
  assert.ok(count > 0);
  let state = 0x2545f491;
  const next = limit => {
    // mulberry32: small, well mixed, and identical in every JS engine.
    state = (state + 0x6d2b79f5) | 0;
    let mixed = Math.imul(state ^ (state >>> 15), 1 | state);
    mixed = (mixed + Math.imul(mixed ^ (mixed >>> 7), 61 | mixed)) ^ mixed;
    return ((mixed ^ (mixed >>> 14)) >>> 0) % limit;
  };
  const literals = [];
  for (let index = 0; index < count; index += 1) {
    const length = 1 + next(7);
    let pattern = '';
    for (let part = 0; part < length; part += 1) pattern += fragments[next(fragments.length)];
    const flags = ['', '', 'u', 'v', 'v'][next(5)];
    literals.push({ pattern, flags, origin: 'constructor' });
  }
  return literals;
}

module.exports = {
  generatedPatterns,
  grammarPatterns, nodeDeviations, propertyPatterns, TABLE_UNICODE_VERSION,
};
