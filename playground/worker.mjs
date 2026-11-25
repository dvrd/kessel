import { createParser } from './parser.mjs';

let parser;
async function load() {
  const response = await fetch(new URL('./kessel.wasm', import.meta.url));
  if (!response.ok) throw new Error('Could not load kessel.wasm (HTTP ' + response.status + ')');
  return createParser(await WebAssembly.compile(await response.arrayBuffer()));
}

const plainText = 'text/plain;charset=utf-8';

// One line per problem, as the Diagnostics view prints them.
function describe(problems) {
  return problems.map(problem => [
    problem.line + ':' + problem.column, problem.severity, problem.rule || problem.code,
    problem.message,
  ].filter(Boolean).join('  ')).join('\n');
}

// A tool that prints code reports problems instead of code when the input
// cannot be processed. They become the request's error.
function generated(result) {
  if (result.errors.length > 0) throw new Error(describe(result.errors));
  return { text: result.code, type: plainText };
}

// Protocol: the page posts {kind, source, options} and receives either
// {error, retry?} or {preview, truncated, file, diagnostics?}. `kind` names a
// method of the reusable binding in parser.mjs; `options` carries the page's
// controls, of which each tool reads the ones it knows.
const tools = {
  parse(source, { language, semanticErrors }) {
    const tree = parser.parse(source, { language, semanticErrors });
    const text = JSON.stringify(tree, null, 2);
    return { text, type: 'application/json', diagnostics: tree.errors ?? [] };
  },
  format(source, { language }) {
    return { text: parser.format(source, { language }), type: plainText };
  },
  lint(source, { language }) {
    const { diagnostics } = parser.lint(source, { language });
    return { text: describe(diagnostics) || 'No lint diagnostics.', type: plainText };
  },
  transform(source, { language, target, jsx }) {
    return generated(parser.transform(source, { language, target, jsx }));
  },
  minify(source, { language }) {
    return generated(parser.minify(source, { language }));
  },
  declaration(source, { language }) {
    return generated(parser.declaration(source, { language }));
  },
};

self.onmessage = async ({ data }) => {
  if (!parser) {
    try { parser = await load(); }
    catch (error) { self.postMessage({ error: error.message, retry: true }); return; }
  }
  try {
    if (!Object.hasOwn(tools, data.kind)) throw new Error('Unknown request ' + data.kind);
    const { text, type, diagnostics } = tools[data.kind](data.source, data.options);
    const previewLimit = 65536;
    self.postMessage({
      preview: text.slice(0, previewLimit), truncated: text.length > previewLimit,
      file: new Blob([text], { type }), diagnostics,
    });
  } catch (error) {
    self.postMessage({ error: error.message });
  }
};
