const get = id => document.getElementById(id);
const source = get('source'), language = get('language'), semantics = get('semantics');
const tree = get('tree'), errors = get('errors'), formatted = get('formatted');
const output = get('output'), download = get('download'), status = get('status'), retry = get('retry');
const cache = new Map();
let view = tree, revision = 0, running, timer, worker;

function operation() {
  return view === formatted ? 'format' : 'parse';
}

function showResult() {
  const kind = operation();
  const result = cache.get(kind);
  const count = cache.get('parse')?.diagnostics?.length;
  errors.textContent = count === undefined ? 'Diagnostics' : 'Diagnostics (' + count + ')';
  retry.hidden = !result?.retry;
  output.textContent = '';
  download.hidden = true;
  download.removeAttribute('href');
  if (!result) { status.textContent = kind === 'format' ? 'Formatting…' : 'Parsing…'; return; }
  if (result.error) { status.textContent = result.error; return; }

  download.href = result.url;
  download.hidden = false;
  download.textContent = kind === 'format' ? 'Download source' : 'Download JSON';
  download.download = kind === 'format' ? 'formatted.' + language.value : 'kessel-ast.json';
  status.textContent = kind === 'format' ? 'Formatted.' : 'Parsed.';
  if (result.truncated && view !== errors) status.textContent += ' Showing the first 65,536 characters. Download the full result.';
  output.textContent = view === errors
    ? result.diagnostics.map(d => [d.line + ':' + d.column, d.code, d.message].filter(Boolean).join('  ')).join('\n') || 'No diagnostics.'
    : result.preview;
}

function run() {
  const kind = operation();
  if (running || cache.has(kind)) return;
  running = {revision, kind};
  try {
    if (!worker) {
      worker = new Worker(new URL('./worker.mjs', import.meta.url), {type: 'module'});
      worker.onmessage = receive;
      worker.onerror = event => {
        worker.terminate();
        worker = undefined;
        receive({data: {error: event.message || 'Could not start the playground worker', retry: true}});
      };
    }
    worker.postMessage({kind, source: source.value, options: {language: language.value, semanticErrors: semantics.checked}});
  } catch (error) { receive({data: {error: error.message, retry: true}}); }
}

function receive({data}) {
  const completed = running;
  running = undefined;
  if (completed?.revision === revision) {
    if (data.file) data.url = URL.createObjectURL(data.file);
    cache.set(completed.kind, data);
  }
  clearTimeout(timer);
  showResult();
  run();
}

function changed() {
  revision++;
  for (const result of cache.values()) if (result.url) URL.revokeObjectURL(result.url);
  cache.clear();
  clearTimeout(timer);
  showResult();
  timer = setTimeout(run, 200);
}
source.addEventListener('input', changed);
language.addEventListener('change', changed);
semantics.addEventListener('change', changed);
retry.addEventListener('click', () => { cache.delete(operation()); showResult(); run(); });
for (const button of [tree, errors, formatted]) {
  button.addEventListener('click', () => {
    view.setAttribute('aria-pressed', 'false');
    view = button;
    view.setAttribute('aria-pressed', 'true');
    showResult();
    run();
  });
}
run();
