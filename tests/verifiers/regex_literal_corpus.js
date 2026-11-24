'use strict';

// Regexp literal extraction for verify_regex_ast_reference.js.
//
// A real tokenizer decides where a `/` starts a regexp literal. Acorn is used
// with its regexp validation removed: acorn rejects patterns it considers
// invalid while tokenizing, which would drop exactly the negative literals the
// gate needs. The override keeps acorn's lexical scan (ECMA-262
// RegularExpressionLiteral: the first unescaped `/` outside a class ends the
// body, classes do not nest lexically) and records the raw body and flags.
//
// Files acorn cannot parse (negative syntax tests, proposals newer than acorn)
// are tokenized without parsing. Acorn tracks regexp-versus-division context
// from token types alone, so the token loop still classifies `/` correctly up
// to the first lexical error. Both fallbacks are counted and reported.

const fs = require('node:fs');
const path = require('node:path');

const acorn = require('../../bench/node_modules/acorn');

function recordingParser(literals) {
  return acorn.Parser.extend(Base => class extends Base {
    readRegexp() {
      const start = this.pos;
      let escaped = false;
      let inClass = false;
      for (;;) {
        if (this.pos >= this.input.length) this.raise(start, 'Unterminated regular expression');
        const ch = this.input.charAt(this.pos);
        if (acorn.lineBreak.test(ch)) this.raise(start, 'Unterminated regular expression');
        if (escaped) {
          escaped = false;
        } else {
          if (ch === '[') inClass = true;
          else if (ch === ']' && inClass) inClass = false;
          else if (ch === '/' && !inClass) break;
          escaped = ch === '\\';
        }
        ++this.pos;
      }
      const pattern = this.input.slice(start, this.pos);
      ++this.pos;
      const flagsStart = this.pos;
      const flags = this.readWord1();
      if (this.containsEsc) this.unexpected(flagsStart);
      literals.push({ pattern, flags, origin: 'literal' });
      return this.finishToken(acorn.tokTypes.regexp, { pattern, flags, value: null });
    }
  });
}

function hasLoneSurrogate(text) {
  return !text.isWellFormed();
}

// `RegExp("...")` and `new RegExp("...", "...")` with constant string
// arguments. The pattern is the cooked string, so unlike a literal body it may
// hold an unescaped `/` or a line terminator.
function collectConstructorCalls(program, found, stats) {
  const stack = [program];
  while (stack.length !== 0) {
    const node = stack.pop();
    if (node.type === 'NewExpression' || node.type === 'CallExpression') {
      const [first, second] = node.arguments;
      const named = node.callee.type === 'Identifier' && node.callee.name === 'RegExp';
      const constant = value => value.type === 'Literal' && typeof value.value === 'string';
      if (named && first && constant(first) && (!second || constant(second)) &&
          node.arguments.length <= 2) {
        const flags = second ? second.value : '';
        if (hasLoneSurrogate(first.value) || hasLoneSurrogate(flags)) {
          // The SDK passes UTF-8, which cannot carry a lone surrogate.
          stats.loneSurrogateStrings += 1;
        } else {
          found.push({ pattern: first.value, flags, origin: 'constructor' });
        }
      }
    }
    for (const key in node) {
      const value = node[key];
      if (value === null || typeof value !== 'object') continue;
      if (Array.isArray(value)) {
        for (const item of value) if (item && typeof item.type === 'string') stack.push(item);
      } else if (typeof value.type === 'string') {
        stack.push(value);
      }
    }
  }
}

function extractFromSource(source, stats) {
  const options = { ecmaVersion: 'latest', allowHashBang: true };
  for (const sourceType of ['script', 'module']) {
    const literals = [];
    try {
      const program = recordingParser(literals).parse(source, { ...options, sourceType });
      collectConstructorCalls(program, literals, stats);
      stats.parsedFiles += 1;
      return literals;
    } catch (_) {
      // Fall through to the next source type, then to the token loop.
    }
  }
  const literals = [];
  const tokenizer = recordingParser(literals)
    .tokenizer(source, { ...options, sourceType: 'module' });
  try {
    for (let token = tokenizer.getToken(); token.type !== acorn.tokTypes.eof;) {
      token = tokenizer.getToken();
    }
    stats.tokenizedFiles += 1;
  } catch (_) {
    stats.partialFiles += 1;
  }
  return literals;
}

function listSourceFiles(root) {
  const files = [];
  const pending = [root];
  while (pending.length !== 0) {
    const directory = pending.pop();
    // statSync follows the corpus symlinks used by worktrees.
    for (const name of fs.readdirSync(directory).sort()) {
      const full = path.join(directory, name);
      const stat = fs.statSync(full);
      if (stat.isDirectory()) pending.push(full);
      else if (/\.(js|mjs|cjs)$/.test(name)) files.push(full);
    }
  }
  return files.sort();
}

function newStats() {
  return { files: 0, parsedFiles: 0, tokenizedFiles: 0, partialFiles: 0, loneSurrogateStrings: 0 };
}

// Returns every literal occurrence in file order; the caller deduplicates.
function extractCorpus(root) {
  const stats = newStats();
  const literals = [];
  for (const file of listSourceFiles(root)) {
    stats.files += 1;
    for (const literal of extractFromSource(fs.readFileSync(file, 'utf8'), stats)) {
      literals.push(literal);
    }
  }
  return { literals, stats };
}

module.exports = { extractCorpus, extractFromSource, newStats };
