import { createParser } from './parser.mjs';

let parser;
async function load() {
  const response = await fetch(new URL('./kessel.wasm', import.meta.url));
  if (!response.ok) throw new Error('Could not load kessel.wasm (HTTP ' + response.status + ')');
  return createParser(await WebAssembly.compile(await response.arrayBuffer()));
}

self.onmessage = async ({data}) => {
  if (!parser) {
    try { parser = await load(); }
    catch (error) { self.postMessage({error: error.message, retry: true}); return; }
  }
  try {
    let text, diagnostics, type;
    if (data.kind === 'format') {
      text = parser.format(data.source, {language: data.options.language});
      type = 'text/plain;charset=utf-8';
    } else {
      const tree = parser.parse(data.source, data.options);
      diagnostics = tree.errors ?? [];
      text = JSON.stringify(tree, null, 2);
      type = 'application/json';
    }
    const previewLimit = 65536;
    self.postMessage({
      preview: text.slice(0, previewLimit), truncated: text.length > previewLimit,
      file: new Blob([text], {type}), diagnostics,
    });
  } catch (error) {
    self.postMessage({error: error.message});
  }
};
