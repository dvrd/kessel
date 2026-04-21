// Strings con todos los escapes
const single = 'It\'s a test';
const double = "He said \"Hello\"";
const escaped = 'Line1\nLine2\tTabbed\r\rCarriage';
const unicode = '\u0041\u{1F600}';
const hexEscape = '\x41\x42\x43';

const backtick = `Template with \` escaped`;
const multiline = `
  First line
  Second line with \n literal
  Third with \t tab and \\ backslash
`;

const regex = /\d+/g;
const regexEscaped = /\/\[\]\(\)/;
