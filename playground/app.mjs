const get = id => document.getElementById(id);
const source = get('source'), language = get('language'), semantics = get('semantics');
const target = get('target'), jsx = get('jsx');
const tree = get('tree'), errors = get('errors');
const output = get('output'), download = get('download'), status = get('status');
const retry = get('retry');
const views = [...document.querySelectorAll('.views button')];
const cache = new Map();
let view = tree, revision = 0, running, timer, worker;

// One entry per worker request kind: what the status line says while it runs
// and when it is done, and how the result is offered for download.
const tools = {
  parse: {
    pending: 'Parsing…', done: 'Parsed.', link: 'Download JSON', file: () => 'kessel-ast.json',
  },
  format: {
    pending: 'Formatting…', done: 'Formatted.', link: 'Download source',
    file: () => 'formatted.' + language.value,
  },
  lint: {
    pending: 'Linting…', done: 'Linted.', link: 'Download report', file: () => 'kessel-lint.txt',
  },
  transform: {
    pending: 'Transforming…', done: 'Transformed.', link: 'Download JavaScript',
    // Preserved JSX is still JSX; everything else is plain JavaScript.
    file: () => jsx.value === 'preserve' && language.value.endsWith('x')
      ? 'transformed.jsx' : 'transformed.js',
  },
  minify: {
    pending: 'Minifying…', done: 'Minified.', link: 'Download minified',
    file: () => 'minified.' + language.value,
  },
  declaration: {
    pending: 'Emitting declarations…', done: 'Declarations emitted.',
    link: 'Download declarations', file: () => 'declarations.d.ts',
  },
};

// Each view button names its request in `data-kind`. The Diagnostics view
// shows the parser's diagnostics, so it shares the AST view's request.
function operation() {
  return view.dataset.kind;
}

function describe(diagnostics) {
  return diagnostics.map(d => [d.line + ':' + d.column, d.code, d.message]
    .filter(Boolean).join('  ')).join('\n') || 'No diagnostics.';
}

function showResult() {
  const kind = operation();
  const tool = tools[kind];
  const result = cache.get(kind);
  const count = cache.get('parse')?.diagnostics?.length;
  errors.textContent = count === undefined ? 'Diagnostics' : 'Diagnostics (' + count + ')';
  retry.hidden = !result?.retry;
  output.textContent = '';
  download.hidden = true;
  download.removeAttribute('href');
  if (!result) { status.textContent = tool.pending; return; }
  if (result.error) { status.textContent = result.error; return; }

  download.href = result.url;
  download.hidden = false;
  download.textContent = tool.link;
  download.download = tool.file();
  status.textContent = tool.done;
  if (result.truncated && view !== errors) {
    status.textContent += ' Showing the first 65,536 characters. Download the full result.';
  }
  output.textContent = view === errors ? describe(result.diagnostics) : result.preview;
}

function run() {
  const kind = operation();
  if (running || cache.has(kind)) return;
  running = { revision, kind };
  try {
    if (!worker) {
      worker = new Worker(new URL('./worker.mjs', import.meta.url), { type: 'module' });
      worker.onmessage = receive;
      worker.onerror = event => {
        worker.terminate();
        worker = undefined;
        const error = event.message || 'Could not start the playground worker';
        receive({ data: { error, retry: true } });
      };
    }
    const options = {
      language: language.value, semanticErrors: semantics.checked,
      target: target.value, jsx: jsx.value,
    };
    worker.postMessage({ kind, source: source.value, options });
  } catch (error) { receive({ data: { error: error.message, retry: true } }); }
}

function receive({ data }) {
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
for (const control of [language, semantics, target, jsx]) {
  control.addEventListener('change', changed);
}
retry.addEventListener('click', () => { cache.delete(operation()); showResult(); run(); });
for (const button of views) {
  button.addEventListener('click', () => {
    view.setAttribute('aria-pressed', 'false');
    view = button;
    view.setAttribute('aria-pressed', 'true');
    showResult();
    run();
  });
}
run();
