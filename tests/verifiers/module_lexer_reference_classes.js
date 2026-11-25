'use strict';

// Difference classes for verify_module_lexer_reference.js.
//
// A file where Kessel and es-module-lexer disagree is only accepted when
// every differing field maps to one of these classes. Classes come in two
// families:
//
// - `lexer-*`: the source is valid (the oracle parses it) and Kessel's whole
//   projection agrees with the oracle's module records, so es-module-lexer is
//   the side that is wrong. `oracleProblems` enforces that agreement for the
//   whole file, not just for the differing field, before any `lexer-*` class
//   is granted.
// - `invalid-*`: no oracle goal accepts the source, so neither lexer has a
//   defined answer. Only the accept/reject outcome is recorded.
//
// The `why` text is the justification printed in reports; `proof` names the
// evidence that settles which side is right.

const ORACLE = 'oxc-parser AST agrees with Kessel on every record of the file';

const CLASSES = {
  'lexer-static-attributes': {
    why: 'es-module-lexer misses a static `with`/`assert` clause that is empty ' +
      '(`with {}`) or separated from the specifier by a line break; it reports ' +
      'a = -1 and ends the statement at the specifier.',
    proof: ORACLE + '; V8 reports the attributes (verify_module_lexer_node.js).',
  },
  'lexer-dynamic-options': {
    why: 'es-module-lexer reports `a` as the first non-blank offset after the comma of ' +
      'import(x, ...): with a trailing comma it points at `)`, and with a comment it ' +
      'differs from the options expression. Kessel reports the options expression.',
    proof: ORACLE + ' (ImportExpression.options range, or none).',
  },
  'lexer-dynamic-specifier-end': {
    why: 'Documented in the es-module-lexer README: for a non-literal dynamic import, or ' +
      'one followed by a comment, `e` runs to the character before `)` instead of ' +
      'ending at the specifier expression.',
    proof: ORACLE + ' (ImportExpression.source range).',
  },
  'lexer-phase-keyword-binding': {
    why: 'es-module-lexer decides the phase from the text after `import`: it misses ' +
      '`import source from from` (a source-phase import of a binding named `from`) ' +
      'and U+2028/U+2029 line separators around `source`, reporting t = 1.',
    proof: ORACLE + ' (ImportDeclaration.phase); V8 reports phase "source" ' +
      '(verify_module_lexer_node.js).',
  },
  'lexer-export-declaration-names': {
    why: 'Documented in the es-module-lexer README: only the first declarator of ' +
      '`export var a = 1, b = 2` is found and destructured names are wrong or missing.',
    proof: ORACLE + ' (bound identifiers of the exported declaration).',
  },
  'lexer-export-local-name': {
    why: 'es-module-lexer reads the token after `export default class` as a local name, ' +
      'so `export default class extends Base {}` gets ln = "extends".',
    proof: ORACLE + ' (the class has no id).',
  },
  'lexer-escaped-export-name': {
    why: 'es-module-lexer returns identifier export names verbatim, so `export { x as ' +
      '\\u03bc }` is reported as the six characters `\\u03bc` instead of the name μ.',
    proof: ORACLE + '; the module namespace key is the decoded name.',
  },
  'lexer-facade-expression-statement': {
    why: 'es-module-lexer keeps facade = true for a module whose only non-declaration ' +
      'code is a literal `import("x")` or a bare `import.meta` statement. Those are ' +
      'expression statements that run in the module, so Kessel reports false.',
    proof: 'The oracle AST has a top-level ExpressionStatement.',
  },
  'lexer-facade-missed': {
    why: 'es-module-lexer drops facade when it mis-lexes a declaration (an attributes ' +
      'clause it does not recognise, a hashbang line) although the module only has ' +
      'import and export declarations.',
    proof: 'Every top-level statement of the oracle AST is an import/export declaration.',
  },
  'lexer-decorated-export': {
    why: 'es-module-lexer does not recognise `export @decorator class Name {}`: it ' +
      'records no export and leaves hasModuleSyntax false.',
    proof: ORACLE + ' (ExportNamedDeclaration with a decorated ClassDeclaration).',
  },
  'lexer-no-typescript': {
    why: 'The source is only valid as TypeScript (`export type`, `export interface`, ' +
      '`import x = require()`). es-module-lexer has no TypeScript support and returns ' +
      'wrong records or throws; Kessel scans TypeScript on purpose.',
    proof: 'oxc-parser accepts the source only under its TypeScript goal and its AST ' +
      'agrees with Kessel on every record of the file.',
  },
  'lexer-parse-error': {
    why: 'es-module-lexer throws on a JavaScript source the oracle accepts.',
    proof: ORACLE + '.',
  },
  'shared-typescript-import-type': {
    why: 'Both lexers report a TypeScript import type (`let x: import("./x").T`) as a ' +
      'dynamic import. Telling a type position from an expression needs a parser; a ' +
      'token scanner cannot, so Kessel keeps es-module-lexer\'s answer.',
    proof: 'oxc-parser (TypeScript goal) yields TSImportType nodes and no ImportExpression.',
  },
  'shared-script-html-comment': {
    why: 'Both lexers scan with the module goal, where `<!--` is not a comment. The ' +
      'source only parses as a script, where it is one, so both see tokens (and drop ' +
      'facade) where a script parser sees nothing.',
    proof: 'oxc-parser rejects the source as a module and accepts it as a script.',
  },
  'invalid-kessel-rejects': {
    why: 'Not valid under any oracle goal; Kessel reports Invalid_Syntax, ' +
      'es-module-lexer returns records for the malformed source.',
    proof: 'oxc-parser rejects the source as module and script, JS and TypeScript.',
  },
  'invalid-lexer-rejects': {
    why: 'Not valid under any oracle goal; es-module-lexer throws, Kessel returns ' +
      'best-effort records.',
    proof: 'oxc-parser rejects the source as module and script, JS and TypeScript.',
  },
  'invalid-records-differ': {
    why: 'Not valid under any oracle goal (syntax errors, Flow, or proposals no parser ' +
      'here implements); both lexers return records and they differ.',
    proof: 'oxc-parser rejects the source as module and script, JS and TypeScript.',
  },
};

function same(left, right) {
  return left === right;
}

// Compare Kessel's projection with the oracle records. Returns a list of
// human-readable problems; empty means full agreement.
function oracleProblems(kessel, records) {
  const problems = [];
  const check = (label, ours, theirs) => {
    if (!same(ours, theirs)) {
      problems.push(`${label}: kessel=${JSON.stringify(ours)} oracle=${JSON.stringify(theirs)}`);
    }
  };
  check('imports.length', kessel.imports.length, records.imports.length);
  check('exports.length', kessel.exports.length, records.exports.length);
  if (problems.length !== 0) return problems;
  kessel.imports.forEach((ours, index) => {
    const theirs = records.imports[index];
    for (const field of ['t', 'ss', 'n', 's', 'e']) {
      check(`imports[${index}].${field}`, ours[field], theirs[field]);
    }
    if (theirs.se !== undefined) check(`imports[${index}].se`, ours.se, theirs.se);
    if (theirs.a !== undefined) check(`imports[${index}].a`, ours.a, theirs.a);
    if (theirs.attributes !== undefined) {
      check(`imports[${index}].attributes`, JSON.stringify(kessel.attributes[index]),
        JSON.stringify(theirs.attributes));
      if (theirs.attributes.length !== 0) check(`imports[${index}].has a`, ours.a >= 0, true);
    }
  });
  kessel.exports.forEach((ours, index) => {
    check(`exports[${index}].n`, ours.n, records.exports[index].n);
    check(`exports[${index}].ln`, ours.ln, records.exports[index].ln);
  });
  check('hasModuleSyntax', kessel.hasModuleSyntax, records.moduleSyntax);
  check('facade', kessel.facade, records.facade);
  return problems;
}

function classifyValid(diff, context) {
  if (diff.field === 'kesselRejects' || diff.field === 'bothReject') return null;
  if (context.problems === undefined) {
    context.problems = oracleProblems(context.kessel, context.oracle.records);
  }
  if (context.problems.length !== 0) return null;
  if (/^tsx?$/.test(context.oracle.goal.lang)) return 'lexer-no-typescript';
  if (diff.field === 'lexerRejects') return 'lexer-parse-error';
  const decorated = context.oracle.records.exports.some(item => item.decorated);
  if (diff.path === 'exports.length') {
    if (context.oracle.records.exports.some(item => item.variable)) {
      return 'lexer-export-declaration-names';
    }
    return decorated ? 'lexer-decorated-export' : null;
  }
  if (diff.field === 'facade') {
    return diff.kessel ? 'lexer-facade-missed' : 'lexer-facade-expression-statement';
  }
  if (diff.field === 'hasModuleSyntax') {
    return diff.kessel && decorated ? 'lexer-decorated-export' : null;
  }
  if (diff.kind === 'exports') return classifyExport(diff, context);
  const ours = context.kessel.imports[diff.index];
  const dynamic = ours.d >= 0;
  if (diff.field === 't') {
    return ours.t === 4 && diff.lexer === 1 ? 'lexer-phase-keyword-binding' : null;
  }
  if (!dynamic && (diff.field === 'a' || diff.field === 'se')) {
    // Kessel found a clause that es-module-lexer did not.
    return ours.a >= 0 && context.lexer.imports[diff.index].a === -1
      ? 'lexer-static-attributes' : null;
  }
  if (dynamic && diff.field === 'a') return 'lexer-dynamic-options';
  if (dynamic && diff.field === 'e') return 'lexer-dynamic-specifier-end';
  return null;
}

function classifyExport(diff, context) {
  const ours = context.kessel.exports[diff.index];
  const theirs = context.lexer.exports[diff.index];
  // Names bound by `export const/let/var`: the documented limitation.
  if (context.oracle.records.exports[diff.index].variable) return 'lexer-export-declaration-names';
  if (diff.field === 'n') {
    return /\\u/.test(theirs.n) && !/\\u/.test(ours.n) ? 'lexer-escaped-export-name' : null;
  }
  if (['ln', 'ls', 'le'].includes(diff.field)) {
    if (context.oracle.records.exports[diff.index].decorated) return 'lexer-decorated-export';
    return ours.ln === undefined && theirs.ln === 'extends' ? 'lexer-export-local-name' : null;
  }
  return null;
}

// --oracle-all: Kessel and es-module-lexer agree with each other but not
// with the oracle. Returns the class id, or null when unexplained.
function classifyShared(context) {
  const { goal, records } = context.oracle;
  const onlyImportCount = context.problems.length === 1 &&
    context.problems[0].startsWith('imports.length');
  if (/^tsx?$/.test(goal.lang) && onlyImportCount &&
      context.kessel.imports.length > records.imports.length) {
    return 'shared-typescript-import-type';
  }
  if (goal.sourceType === 'script' && /<!--|-->/.test(context.source)) {
    return 'shared-script-html-comment';
  }
  return null;
}

// Returns the class id for one field difference, or null when the difference
// is not explained (which fails the gate).
function classify(diff, context) {
  if (context.oracle.valid) return classifyValid(diff, context);
  if (diff.field === 'kesselRejects') return 'invalid-kessel-rejects';
  if (diff.field === 'lexerRejects') return 'invalid-lexer-rejects';
  if (diff.field === 'bothReject') return null;
  return 'invalid-records-differ';
}

module.exports = { CLASSES, classify, classifyShared, oracleProblems };
