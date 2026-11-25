#!/usr/bin/env node
// Nesting-depth gate.
//
// Goal: no input may overflow the native stack. An embedder that runs
// kessel in-process (a dev server calling the library) loses the whole
// process to a stack overflow, so this gate drives every recursive path
// with inputs far past the sizes that used to crash and requires an
// ordinary exit, never a signal.
//
// Methodology. Inputs are generated here (the large ones are megabytes)
// and each run is a child process started under an explicit `ulimit -s`.
// Odin sizes worker-thread stacks from the same rlimit, so this is the
// situation of a library consumer on a thread of that size, not only of
// the CLI's main thread. Both the optimised binary (bin/kessel) and the
// unoptimised one (bin/kessel-debug, frames several times larger) run
// every section.
//
//   1. reject   Every nesting shape at 5,000 levels: more than twice the
//               depth that used to crash an optimised build (about 2,240)
//               and six times the debug figure (about 760). Expect
//               exactly one diagnostic, K2081, with a real span; no
//               cascade; every consumer survives.
//   2. limit    Every nesting shape at the deepest level the parser still
//               accepts (found by bisection). Every consumer must walk
//               that tree on the constrained stack. This is what shows
//               the default limit fits the stack, rather than assuming it.
//   3. chains   Binary / logical / member / call chains are built in a
//               loop and are not limited. 1,000,000 terms must parse and
//               check with no diagnostic, and every consumer must survive.
//   4. contexts The same chains embedded where specialised walkers run
//               (parameter defaults, class fields, enum initialisers,
//               assignment targets, ...), at 60,000 terms on the optimised
//               build and 10,000 on the debug build: each more than twice
//               the length that used to crash that build (about 29,000
//               and 4,200).
//   5. api      --max-depth, diagnostic ordering, and what is kept in the
//               tree when the limit is hit.
//
// Usage:
//   node tests/verifiers/verify_depth_limit.js            # the gate
//   node tests/verifiers/verify_depth_limit.js --full     # contexts x all tools
//   node tests/verifiers/verify_depth_limit.js --only=chains,api
//   node tests/verifiers/verify_depth_limit.js --verbose
//
// Exit 0 when every expectation holds, 1 otherwise.

'use strict';
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn } = require('child_process');

const ROOT = path.resolve(__dirname, '../..');
const BUILDS = [
  { name: 'release', bin: process.env.KESSEL_RELEASE_BIN || path.join(ROOT, 'bin/kessel'), context_terms: 60000 },
  { name: 'debug', bin: process.env.KESSEL_DEBUG_BIN || path.join(ROOT, 'bin/kessel-debug'), context_terms: 10000 },
];

const ARGS = process.argv.slice(2);
const VERBOSE = ARGS.includes('--verbose');
const FULL = ARGS.includes('--full');
const ONLY = (ARGS.find(a => a.startsWith('--only=')) || '').slice(7).split(',').filter(Boolean);

// The stack every child gets, in KB. 8 MB is the default main-thread
// stack on macOS and Linux and what the embedder that reported the
// overflows runs with.
const STACK_KB = 8192;
const REJECT_LEVELS = 5000;
const CHAIN_TERMS = 1000000;
const LIMIT_SEARCH_MAX = 2048;
const RUN_TIMEOUT_MS = 120000;
const DEPTH_CODE = 'K2081';
const CONCURRENCY = Math.max(2, Math.min(6, os.cpus().length - 2));

const rep = (text, count) => text.repeat(count);

// ---------------------------------------------------------------------------
// Shapes
// ---------------------------------------------------------------------------

// Constructs that nest by recursion in the parser. `gen(n)` nests n levels.
const NESTED = {
  parens:       { ext: 'js',  gen: n => rep('(', n) + '1' + rep(')', n) + ';' },
  arrays:       { ext: 'js',  gen: n => 'x=' + rep('[', n) + rep(']', n) + ';' },
  objects:      { ext: 'js',  gen: n => 'x=' + rep('{a:', n) + '1' + rep('}', n) + ';' },
  calls:        { ext: 'js',  gen: n => rep('f(', n) + rep(')', n) + ';' },
  arrows:       { ext: 'js',  gen: n => 'x=' + rep('a=>', n) + '1;' },
  ternary_alt:  { ext: 'js',  gen: n => 'x=' + rep('a?b:', n) + '1;' },
  ternary_con:  { ext: 'js',  gen: n => 'x=' + rep('a?', n) + '1' + rep(':1', n) + ';' },
  assignments:  { ext: 'js',  gen: n => rep('a=', n) + '1;' },
  unary_not:    { ext: 'js',  gen: n => 'x=' + rep('!', n) + '1;' },
  unary_typeof: { ext: 'js',  gen: n => 'x=' + rep('typeof ', n) + '1;' },
  unary_minus:  { ext: 'js',  gen: n => 'x=' + rep('- ', n) + '1;' },
  await_chain:  { ext: 'mjs', gen: n => 'x=' + rep('await ', n) + '1;' },
  new_chain:    { ext: 'js',  gen: n => 'x=' + rep('new ', n) + 'a;' },
  pow_chain:    { ext: 'js',  gen: n => 'x=' + rep('a**', n) + '1;' },
  spread:       { ext: 'js',  gen: n => 'x=' + rep('[...', n) + 'a' + rep(']', n) + ';' },
  blocks:       { ext: 'js',  gen: n => rep('{', n) + rep('}', n) },
  else_if:      { ext: 'js',  gen: n => rep('if(a){}else ', n) + '{}' },
  if_nested:    { ext: 'js',  gen: n => rep('if(a)', n) + ';' },
  while_nested: { ext: 'js',  gen: n => rep('while(a)', n) + ';' },
  labels:       { ext: 'js',  gen: n => Array.from({ length: n }, (_, i) => `l${i}:`).join('') + ';' },
  functions:    { ext: 'js',  gen: n => rep('function f(){', n) + rep('}', n) },
  fn_exprs:     { ext: 'js',  gen: n => 'x=' + rep('function(){return ', n) + '1' + rep('}', n) + ';' },
  classes:      { ext: 'js',  gen: n => 'x=' + rep('class{m(){return ', n) + '1' + rep('}}', n) + ';' },
  class_extends:{ ext: 'js',  gen: n => 'x=' + rep('class extends ', n) + 'a' + rep('{}', n) + ';' },
  jsx:          { ext: 'jsx', gen: n => 'x=' + rep('<a>', n) + rep('</a>', n) + ';' },
  jsx_expr:     { ext: 'jsx', gen: n => 'x=' + rep('<a>{', n) + '1' + rep('}</a>', n) + ';' },
  jsx_attr:     { ext: 'jsx', gen: n => 'x=' + rep('<a b=', n) + '<a/>' + rep('/>', n) + ';' },
  bind_array:   { ext: 'js',  gen: n => 'var ' + rep('[', n) + 'a' + rep(']', n) + '=x;' },
  bind_object:  { ext: 'js',  gen: n => 'var ' + rep('{a:', n) + 'a' + rep('}', n) + '=x;' },
  param_array:  { ext: 'js',  gen: n => 'function f(' + rep('[', n) + 'a' + rep(']', n) + '){}' },
  assign_pat:   { ext: 'js',  gen: n => rep('[', n) + 'a' + rep(']', n) + '=x;' },
  ts_tuple:     { ext: 'ts',  gen: n => 'type A=' + rep('[', n) + 'number' + rep(']', n) + ';' },
  ts_generic:   { ext: 'ts',  gen: n => 'type A=' + rep('B<', n) + 'number' + rep('>', n) + ';' },
  ts_paren:     { ext: 'ts',  gen: n => 'type A=' + rep('(', n) + 'number' + rep(')', n) + ';' },
  ts_fn_type:   { ext: 'ts',  gen: n => 'type A=' + rep('()=>', n) + 'number;' },
  ts_keyof:     { ext: 'ts',  gen: n => 'type A=' + rep('keyof ', n) + 'B;' },
  ts_cond:      { ext: 'ts',  gen: n => 'type A=' + rep('B extends C?D:', n) + 'E;' },
  ts_objtype:   { ext: 'ts',  gen: n => 'type A=' + rep('{a:', n) + 'number' + rep('}', n) + ';' },
  ts_assert:    { ext: 'ts',  gen: n => 'x=' + rep('<A>', n) + 'a;' },
  ts_namespace: { ext: 'ts',  gen: n => rep('namespace a{', n) + rep('}', n) },
  ts_ns_dotted: { ext: 'ts',  gen: n => 'namespace a' + rep('.a', n) + '{}' },
  // Wrappers the parser builds in a loop but walkers recurse through. Each
  // one is charged against the same limit, so these are rejected as well.
  tagged:       { ext: 'js',  gen: n => 'x=a' + rep('``', n) + ';' },
  ts_as:        { ext: 'ts',  gen: n => 'x=a' + rep(' as A', n) + ';' },
  ts_nonnull:   { ext: 'ts',  gen: n => 'x=a' + rep('!.b', n) + ';' },
  ts_array:     { ext: 'ts',  gen: n => 'type A=B' + rep('[]', n) + ';' },
  ts_indexed:   { ext: 'ts',  gen: n => 'type A=B' + rep('[C]', n) + ';' },
  ts_qualified: { ext: 'ts',  gen: n => 'type A=B' + rep('.C', n) + ';' },
  jsx_member:   { ext: 'jsx', gen: n => 'x=<a' + rep('.b', n) + '/>;' },
};

// Chains the parser builds in a loop and does not limit. `gen(n)` is an
// expression of n terms with no trailing semicolon.
const CHAIN = {
  plus:     n => '1' + rep('+1', n - 1),
  and:      n => 'a' + rep('&&a', n - 1),
  member:   n => 'a' + rep('.b', n - 1),
  call:     n => 'a' + rep('()', n - 1),
  // Further shapes of the same four node kinds.
  strcat:   n => "'a'" + rep("+'a'", n - 1),
  mixed:    n => 'a' + rep('+a*a-a', Math.floor(n / 3)),
  or:       n => 'a' + rep('||a', n - 1),
  nullish:  n => 'a' + rep('??a', n - 1),
  index:    n => 'a' + rep('[0]', n - 1),
  method:   n => 'a' + rep('.b(1)', Math.floor(n / 2)),
  optional: n => 'a' + rep('?.b', n - 1),
  opt_call: n => 'a' + rep('?.()', n - 1),
  this_m:   n => 'this' + rep('.b', n - 1),
};
// The four chains the million-term requirement names, then the variants.
const CHAIN_REQUIRED = ['plus', 'and', 'member', 'call'];
const CHAIN_VARIANTS = ['strcat', 'mixed', 'or', 'nullish', 'index', 'method', 'optional', 'opt_call'];
const MEMBER_LIKE = ['member', 'index', 'this_m'];

// Places a chain can sit. Each reaches a different walker or check.
const CONTEXT = {
  stmt:         { ext: 'js',  wrap: c => `${c};` },
  var_init:     { ext: 'js',  wrap: c => `var x=${c};` },
  let_init:     { ext: 'js',  wrap: c => `let x=${c};` },
  fn_return:    { ext: 'js',  wrap: c => `function f(){return ${c};}` },
  arrow_body:   { ext: 'js',  wrap: c => `x=()=>${c};` },
  arrow_param:  { ext: 'js',  wrap: c => `x=(p=${c})=>p;` },
  fn_param:     { ext: 'js',  wrap: c => `function f(p=${c}){}` },
  call_arg:     { ext: 'js',  wrap: c => `f(${c});` },
  array_el:     { ext: 'js',  wrap: c => `x=[${c}];` },
  obj_value:    { ext: 'js',  wrap: c => `x={k:${c}};` },
  obj_key:      { ext: 'js',  wrap: c => `x={[${c}]:1};` },
  template:     { ext: 'js',  wrap: c => 'x=`${' + c + '}`;' },
  if_test:      { ext: 'js',  wrap: c => `if(${c}){}` },
  while_test:   { ext: 'js',  wrap: c => `while(${c}){}` },
  for_init:     { ext: 'js',  wrap: c => `for(x=${c};;){}` },
  for_of:       { ext: 'js',  wrap: c => `for(const x of ${c}){}` },
  switch_case:  { ext: 'js',  wrap: c => `switch(${c}){case ${c}:}` },
  throw_arg:    { ext: 'js',  wrap: c => `throw ${c};` },
  cond_test:    { ext: 'js',  wrap: c => `x=${c}?1:2;` },
  cond_alt:     { ext: 'js',  wrap: c => `x=a?1:${c};` },
  unary_arg:    { ext: 'js',  wrap: c => `x=!(${c});` },
  typeof_arg:   { ext: 'js',  wrap: c => `x=typeof ${c};` },
  await_arg:    { ext: 'mjs', wrap: c => `x=await ${c};` },
  yield_arg:    { ext: 'js',  wrap: c => `function*g(){yield ${c};}` },
  spread_arg:   { ext: 'js',  wrap: c => `f(...${c});` },
  new_arg:      { ext: 'js',  wrap: c => `new F(${c});` },
  class_field:  { ext: 'js',  wrap: c => `class A{x=${c};}` },
  class_static: { ext: 'js',  wrap: c => `class A{static x=${c};static{${c};}}` },
  class_method: { ext: 'js',  wrap: c => `class A extends B{constructor(){super();this.x=${c};}m(){return ${c};}}` },
  class_key:    { ext: 'js',  wrap: c => `class A{[${c}](){}}` },
  export_def:   { ext: 'mjs', wrap: c => `export default ${c};` },
  export_const: { ext: 'mjs', wrap: c => `export const x=${c};` },
  jsx_attr:     { ext: 'jsx', wrap: c => `x=<a b={${c}}/>;` },
  jsx_child:    { ext: 'jsx', wrap: c => `x=<a>{${c}}</a>;` },
  ts_enum:      { ext: 'ts',  wrap: c => `enum E{A=${c}}` },
  ts_as:        { ext: 'ts',  wrap: c => `export const x:number=(${c}) as number;` },
  ts_namespace: { ext: 'ts',  wrap: c => `namespace N{export const x=${c};}` },
  ts_function:  { ext: 'ts',  wrap: c => `export function f():number{return ${c};}` },
  sequence:     { ext: 'js',  wrap: c => `x=(1,${c});` },
  assign_rhs:   { ext: 'js',  wrap: c => `a.b=c=${c};` },
  import_arg:   { ext: 'mjs', wrap: c => `import(${c});` },
  labeled:      { ext: 'js',  wrap: c => `l:{${c};break l;}` },
  try_blocks:   { ext: 'js',  wrap: c => `try{${c};}catch(e){${c};}finally{${c};}` },
  accessors:    { ext: 'js',  wrap: c => `x={get k(){return ${c};},set k(v){${c};}};` },
  async_arrow:  { ext: 'js',  wrap: c => `x=async()=>{await ${c};};` },
  destructure:  { ext: 'js',  wrap: c => `var {k=${c}}=o,[e=${c}]=o;` },
};
// Positions that only take a member-like chain: assignment targets, callees.
const CONTEXT_MEMBER = {
  assign_target: { ext: 'js',  wrap: c => `${c}=1;` },
  compound:      { ext: 'js',  wrap: c => `${c}+=1;` },
  update_post:   { ext: 'js',  wrap: c => `${c}++;` },
  update_pre:    { ext: 'js',  wrap: c => `++${c};` },
  delete_arg:    { ext: 'js',  wrap: c => `delete ${c};` },
  for_in_target: { ext: 'js',  wrap: c => `for(${c} in o){}` },
  array_target:  { ext: 'js',  wrap: c => `[${c}]=o;` },
  object_target: { ext: 'js',  wrap: c => `({k:${c}}=o);` },
  rest_target:   { ext: 'js',  wrap: c => `[...${c}]=o;` },
  new_callee:    { ext: 'js',  wrap: c => `new ${c}();` },
  template_tag:  { ext: 'js',  wrap: c => c + '`t`;' },
  class_extends: { ext: 'js',  wrap: c => `class A extends ${c}{}` },
  decorator:     { ext: 'ts',  wrap: c => `@(${c}) class A{}` },
  jsx_spread:    { ext: 'jsx', wrap: c => `x=<a {...${c}}/>;` },
  ts_nonnull:    { ext: 'ts',  wrap: c => `x=${c}!;` },
};

// ---------------------------------------------------------------------------
// Consumers
// ---------------------------------------------------------------------------

// Every tool that walks the tree. `args(file, tmp)` is the command line.
const TOOLS = {
  check:       (f) => ['parse', f, '--show-semantic-errors'],
  json:        (f) => ['parse', f, '--json', '--compact'],
  binary:      (f) => ['parse', f, '--binary'],
  raw:         (f, tmp) => ['raw', f, '--out', path.join(tmp, 'out.raw')],
  raw_batch:   (f, tmp) => ['parse', f, '--raw', '--out-dir', tmp],
  codegen:     (f) => ['codegen', f],
  codegen_min: (f) => ['codegen', f, '--minified'],
  lint:        (f) => ['lint', f],
  minify:      (f) => ['minify', f],
  dts:         (f) => ['dts', f],
  fmt:         (f) => ['fmt', f],
  transform:   (f) => ['transform', f],
  strip_types: (f) => ['strip-types', f],
  // The bundler adds its own walkers (scan, side-effect analysis) and then
  // reparses and checks what it printed.
  bundle:      (f, tmp) => ['bundle', f, '--outfile', path.join(tmp, 'bundle.out.js')],
  // The lowerings have walkers and rewrite rules of their own. A chain of
  // `??` or `?.` too long to lower is refused, which is exit status 1.
  transform_es2015:     (f) => ['transform', f, '--target=es2015'],
  transform_decorators: (f) => ['transform', f, '--decorators=legacy'],
  transform_refresh:    (f) => ['transform', f, '--react-refresh'],
};
const LOWERING_TOOLS = ['transform_es2015', 'transform_decorators', 'transform_refresh'];
const TOOL_NAMES = Object.keys(TOOLS);

// ---------------------------------------------------------------------------
// Runner
// ---------------------------------------------------------------------------

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'kessel-depth-'));
process.on('exit', () => { try { fs.rmSync(TMP, { recursive: true, force: true }); } catch (_) {} });

let failures = 0;
let checks = 0;
const failure_lines = [];
function fail(message) {
  failures += 1;
  if (failure_lines.length < 60) failure_lines.push(message);
}
function expect(condition, message) {
  checks += 1;
  if (!condition) fail(message);
  return condition;
}

let file_counter = 0;
function write_source(ext, text) {
  file_counter += 1;
  const dir = path.join(TMP, String(file_counter));
  fs.mkdirSync(dir);
  const file = path.join(dir, `input.${ext}`);
  fs.writeFileSync(file, text);
  return { file, dir };
}
function release_source(source) {
  try { fs.rmSync(source.dir, { recursive: true, force: true }); } catch (_) {}
}

// Run `bin args...` with the constrained stack. stdout is kept only when
// the caller asks (it can be hundreds of megabytes); stderr is capped.
function run(bin, args, options = {}) {
  return new Promise(resolve => {
    const quoted = [bin, ...args].map(a => `'${String(a).replace(/'/g, `'\\''`)}'`).join(' ');
    const child = spawn('/bin/sh', ['-c', `ulimit -s ${STACK_KB} && exec ${quoted}`], {
      stdio: ['ignore', options.stdout ? 'pipe' : 'ignore', 'pipe'],
    });
    const started = Date.now();
    let stderr = '';
    const stdout_chunks = [];
    let timed_out = false;
    const timer = setTimeout(() => { timed_out = true; child.kill('SIGKILL'); }, RUN_TIMEOUT_MS);
    child.stderr.on('data', d => { if (stderr.length < 65536) stderr += d.toString('utf8'); });
    if (options.stdout) child.stdout.on('data', d => stdout_chunks.push(d));
    child.on('close', (status, signal) => {
      clearTimeout(timer);
      resolve({
        status, signal, timed_out, stderr,
        stdout: options.stdout ? Buffer.concat(stdout_chunks).toString('utf8') : '',
        ms: Date.now() - started,
      });
    });
  });
}

// Bounded-concurrency map: the machine may be busy, and the million-term
// inputs take real memory.
async function for_each(items, worker) {
  let next = 0;
  async function lane() {
    while (next < items.length) {
      const index = next;
      next += 1;
      await worker(items[index]);
    }
  }
  await Promise.all(Array.from({ length: Math.min(CONCURRENCY, items.length) }, lane));
}

const depth_errors = text => (text.match(new RegExp(`\\[${DEPTH_CODE}\\]`, 'g')) || []).length;
const error_headers = text => (text.replace(/\x1b\[[0-9;]*m/g, '').match(/^error(\[|:)/gm) || []).length;

// A consumer survives when the process ends by itself with an ordinary
// status: 0, or 1 for "the input has diagnostics".
function expect_survived(result, label) {
  if (result.timed_out) return expect(false, `${label}: no result after ${RUN_TIMEOUT_MS} ms`);
  if (result.signal) return expect(false, `${label}: killed by ${result.signal}`);
  return expect(result.status === 0 || result.status === 1,
    `${label}: exit status ${result.status} (${result.stderr.split('\n')[0]})`);
}

async function run_all_tools(build, source, label, tools = TOOL_NAMES) {
  for (const tool of tools) {
    const result = await run(build.bin, TOOLS[tool](source.file, source.dir));
    expect_survived(result, `${label} ${tool}`);
  }
}

// ---------------------------------------------------------------------------
// Section 1 — nesting far past the limit is rejected with one diagnostic
// ---------------------------------------------------------------------------

async function section_reject(build) {
  await for_each(Object.entries(NESTED), async ([name, shape]) => {
    const label = `[${build.name}] reject ${name} x${REJECT_LEVELS}`;
    const source = write_source(shape.ext, shape.gen(REJECT_LEVELS));

    const human = await run(build.bin, ['parse', source.file, '--show-semantic-errors']);
    if (expect_survived(human, label)) {
      expect(human.status === 1, `${label}: expected exit 1, got ${human.status}`);
      expect(depth_errors(human.stderr) === 1,
        `${label}: expected one ${DEPTH_CODE}, got ${depth_errors(human.stderr)}`);
      expect(error_headers(human.stderr) === 1,
        `${label}: expected one diagnostic, got ${error_headers(human.stderr)} (cascade)`);
      // Located: the renderer points at a source position. (The caret
      // line is not checked: these inputs are single lines of up to
      // 100 KB and the captured stderr is capped.)
      const plain = human.stderr.replace(/\x1b\[[0-9;]*m/g, '');
      expect(/-->\s.+:\d+:\d+/.test(plain), `${label}: diagnostic carries no source position`);
    }

    const json = await run(build.bin, ['parse', source.file, '--json', '--compact'], { stdout: true });
    if (expect_survived(json, `${label} json`)) {
      let errors = null;
      try { errors = JSON.parse(json.stdout).errors; } catch (_) {}
      if (expect(Array.isArray(errors) && errors.length === 1,
        `${label}: JSON errors array should hold exactly one entry`)) {
        const only = errors[0];
        expect(only.code === DEPTH_CODE, `${label}: JSON error code is ${only.code}, expected ${DEPTH_CODE}`);
        expect(Number.isInteger(only.offset) && only.offset > 0 && only.offset < shape.gen(REJECT_LEVELS).length,
          `${label}: JSON error offset ${only.offset} is not inside the source`);
      }
    }

    await run_all_tools(build, source, label, TOOL_NAMES.filter(t => t !== 'check' && t !== 'json'));
    release_source(source);
  });

  // Template literals nest through `${`. They are rejected like the rest
  // but stay out of the "limit" section: the lexer tracks only a few
  // levels of template nesting, an unrelated restriction.
  const label = `[${build.name}] reject templates x${REJECT_LEVELS}`;
  const source = write_source('js', 'x=' + rep('`${', REJECT_LEVELS) + '1' + rep('}`', REJECT_LEVELS) + ';');
  await run_all_tools(build, source, label);
  release_source(source);
}

// ---------------------------------------------------------------------------
// Section 2 — the deepest accepted nesting is safe for every consumer
// ---------------------------------------------------------------------------

// Largest n for which the parser accepts shape.gen(n) under the default
// limit. Bisection needs monotonic acceptance, which holds: deeper nesting
// only ever uses more of the budget.
async function deepest_accepted(build, shape) {
  const accepted = async n => {
    const source = write_source(shape.ext, shape.gen(n));
    const result = await run(build.bin, ['parse', source.file]);
    release_source(source);
    return !result.signal && depth_errors(result.stderr) === 0;
  };
  if (!(await accepted(1))) return 0;
  let low = 1;
  let high = LIMIT_SEARCH_MAX;
  if (await accepted(high)) return high;
  while (high - low > 1) {
    const middle = (low + high) >> 1;
    if (await accepted(middle)) low = middle; else high = middle;
  }
  return low;
}

const deepest_cache = new Map();
async function section_limit(build) {
  await for_each(Object.entries(NESTED), async ([name, shape]) => {
    // The limit is a property of the parser, identical in both builds;
    // bisect once on the first build and reuse.
    if (!deepest_cache.has(name)) deepest_cache.set(name, await deepest_accepted(build, shape));
    const levels = deepest_cache.get(name);
    const label = `[${build.name}] limit ${name} x${levels}`;
    // Every shape nests at one or two budget units per level, so at least
    // 200 levels fit in the default 512.
    if (!expect(levels >= 200 && levels < LIMIT_SEARCH_MAX,
      `${label}: deepest accepted nesting should be in [200, ${LIMIT_SEARCH_MAX})`)) return;
    const source = write_source(shape.ext, shape.gen(levels));
    const checked = await run(build.bin, ['parse', source.file, '--show-semantic-errors']);
    if (expect_survived(checked, `${label} check`)) {
      expect(depth_errors(checked.stderr) === 0, `${label}: accepted depth reported ${DEPTH_CODE}`);
    }
    await run_all_tools(build, source, label, TOOL_NAMES.filter(t => t !== 'check'));
    release_source(source);
    if (VERBOSE) console.log(`  ${label}`);
  });
}

// ---------------------------------------------------------------------------
// Section 3 — million-term chains parse, check and survive every consumer
// ---------------------------------------------------------------------------

async function section_chains(build) {
  const jobs = [];
  for (const name of CHAIN_REQUIRED) jobs.push({ name, terms: CHAIN_TERMS, tools: TOOL_NAMES });
  // The variants exercise the same loops through other node fields; the
  // checker and one printer are enough at this size.
  for (const name of CHAIN_VARIANTS) {
    jobs.push({ name, terms: CHAIN_TERMS, tools: ['check', 'codegen', ...LOWERING_TOOLS] });
  }
  await for_each(jobs, async job => {
    const label = `[${build.name}] chain ${job.name} x${job.terms}`;
    const source = write_source('js', `x=${CHAIN[job.name](job.terms)};`);
    const checked = await run(build.bin, ['parse', source.file, '--show-semantic-errors']);
    if (expect_survived(checked, `${label} check`)) {
      expect(checked.status === 0, `${label}: expected exit 0, got ${checked.status}: ${checked.stderr.slice(0, 200)}`);
      expect(error_headers(checked.stderr) === 0, `${label}: valid chain reported a diagnostic`);
    }
    await run_all_tools(build, source, label, job.tools.filter(t => t !== 'check' && t !== 'dts'));
    release_source(source);

    // Declaration emit only accepts TypeScript, so it gets the chain as an
    // annotated export (emitted as-is: exit 0) and as an unannotated one
    // (the initializer is inspected for inference, then reported).
    if (job.tools.includes('dts')) {
      const chain = CHAIN[job.name](job.terms);
      const annotated = write_source('ts', `export const x: number = ${chain};`);
      const emitted = await run(build.bin, TOOLS.dts(annotated.file, annotated.dir));
      if (expect_survived(emitted, `${label} dts annotated`)) {
        expect(emitted.status === 0, `${label}: dts of an annotated export should exit 0`);
      }
      release_source(annotated);
      const inferred = write_source('ts', `export const x = ${chain};\nexport function f() { return ${chain}; }`);
      expect_survived(await run(build.bin, TOOLS.dts(inferred.file, inferred.dir)), `${label} dts inferred`);
      release_source(inferred);
    }
    if (VERBOSE) console.log(`  ${label} ${checked.ms} ms`);
  });

  // Async functions below ES2017 are scanned for what they take from their
  // surroundings and then printed from inside a generator: as a declaration,
  // an arrow and a method, and along a chain that starts at `super`.
  const lowered = [...CHAIN_REQUIRED.map(name => [name, CHAIN[name](CHAIN_TERMS)]),
    ['super', 'super' + rep('.b', CHAIN_TERMS)], ['new_super', 'new super' + rep('.b', CHAIN_TERMS) + '()']];
  await for_each(lowered, async ([name, chain]) => {
    const label = `[${build.name}] async chain ${name} x${CHAIN_TERMS}`;
    const member = name === 'super' || name === 'new_super';
    const source = write_source('js', member ? `class A extends B{async m(){return await ${chain};}}` :
      `async function f(p=1){return await (${chain});}x=async()=>${chain};class A{async m(){return ${chain};}}`);
    const result = await run(build.bin, TOOLS.transform_es2015(source.file, source.dir));
    if (expect_survived(result, `${label} transform_es2015`)) {
      expect(result.status === 0, `${label}: expected exit 0, got ${result.status}: ${result.stderr.slice(0, 200)}`);
    }
    release_source(source);
    if (VERBOSE) console.log(`  ${label}`);
  });

  // Pretty JSON nests one object per link. Indentation is clamped so the
  // document stays linear in the chain length; 60,000 terms would
  // otherwise need about 20 GB.
  const pretty_source = write_source('js', `x=${CHAIN.plus(60000)};`);
  const pretty = await run(build.bin, ['parse', pretty_source.file, '--json'], { stdout: true });
  if (expect_survived(pretty, `[${build.name}] chain plus x60000 pretty json`)) {
    expect(pretty.stdout.length < 400 * 1024 * 1024,
      `[${build.name}] pretty JSON is ${pretty.stdout.length} bytes: indentation is not clamped`);
    let parsed = false;
    try { JSON.parse(pretty.stdout); parsed = true; } catch (_) {
      // V8 itself refuses to parse JSON this deep; that is its limit, not
      // ours. Fall back to checking the document is complete.
      parsed = pretty.stdout.startsWith('{') && pretty.stdout.trimEnd().endsWith('}');
    }
    expect(parsed, `[${build.name}] pretty JSON for a 60000-term chain is not a complete document`);
  }
  release_source(pretty_source);

  // The batch path parses on worker threads, whose stacks come from the
  // same rlimit: a chain and a deep rejection must both survive there.
  const first = write_source('js', `x=${CHAIN.plus(200000)};`);
  const second = write_source('js', NESTED.arrays.gen(REJECT_LEVELS));
  const out_dir = path.join(first.dir, 'out');
  const batch = await run(build.bin, ['parse', first.file, second.file, '--workers', '2', '--out-dir', out_dir]);
  expect_survived(batch, `[${build.name}] worker-thread batch`);
  release_source(first);
  release_source(second);
}

// ---------------------------------------------------------------------------
// Section 4 — chains inside every context that has its own walker
// ---------------------------------------------------------------------------

async function section_contexts(build) {
  const jobs = [];
  const chain_names = [...CHAIN_REQUIRED, ...CHAIN_VARIANTS, 'this_m'];
  for (const chain of chain_names) {
    for (const [context, spec] of Object.entries(CONTEXT)) jobs.push({ chain, context, spec });
    if (MEMBER_LIKE.includes(chain)) {
      for (const [context, spec] of Object.entries(CONTEXT_MEMBER)) jobs.push({ chain, context, spec });
    }
  }
  const tools = FULL ? TOOL_NAMES : ['check'];
  await for_each(jobs, async job => {
    const label = `[${build.name}] context ${job.context}/${job.chain} x${build.context_terms}`;
    const source = write_source(job.spec.ext, job.spec.wrap(CHAIN[job.chain](build.context_terms)));
    await run_all_tools(build, source, label, tools);
    release_source(source);
  });
}

// ---------------------------------------------------------------------------
// Section 5 — the knob and the shape of the result
// ---------------------------------------------------------------------------

async function section_api(build) {
  const tag = `[${build.name}] api`;
  const nested = levels => write_source('js', NESTED.arrays.gen(levels));

  // --max-depth lowers and raises the limit.
  let source = nested(40);
  let result = await run(build.bin, ['parse', source.file, '--max-depth=32']);
  expect(result.status === 1 && depth_errors(result.stderr) === 1, `${tag}: --max-depth=32 should reject 40 levels`);
  expect(/limit 32\b/.test(result.stderr), `${tag}: diagnostic should name the limit in force`);
  result = await run(build.bin, ['parse', source.file, '--max-depth=64']);
  expect(result.status === 0, `${tag}: --max-depth=64 should accept 40 levels`);
  result = await run(build.bin, ['parse', source.file]);
  expect(result.status === 0, `${tag}: the default limit should accept 40 levels`);
  release_source(source);

  source = nested(600);
  result = await run(build.bin, ['parse', source.file]);
  expect(result.status === 1 && /limit 512\b/.test(result.stderr), `${tag}: the default limit should be 512`);
  result = await run(build.bin, ['parse', source.file, '--max-depth=1024']);
  expect(result.status === 0 && !result.signal, `${tag}: --max-depth=1024 should accept 600 levels`);
  release_source(source);

  // There is no "unlimited": zero, negatives and junk are usage errors.
  source = nested(4);
  for (const bad of ['0', '-1', 'abc', '99999999999']) {
    result = await run(build.bin, ['parse', source.file, `--max-depth=${bad}`]);
    expect(result.status === 2, `${tag}: --max-depth=${bad} should be a usage error, got ${result.status}`);
  }
  release_source(source);

  // Diagnostics reported before the limit are kept, in order, and the
  // depth diagnostic comes last. Nothing after it is reported.
  source = write_source('js', `var = 2;\n${NESTED.parens.gen(REJECT_LEVELS)}\nvar = 4;\n`);
  result = await run(build.bin, ['parse', source.file, '--json', '--compact'], { stdout: true });
  if (expect_survived(result, `${tag} ordering`)) {
    let errors = [];
    try { errors = JSON.parse(result.stdout).errors || []; } catch (_) {}
    expect(errors.length === 2 && errors[0].offset < 8,
      `${tag}: expected the earlier diagnostic then ${DEPTH_CODE}, got ${errors.length} diagnostics`);
    expect(errors.filter(e => JSON.stringify(e).includes(DEPTH_CODE)).length === 1,
      `${tag}: exactly one ${DEPTH_CODE} expected`);
    expect(errors.length > 0 && JSON.stringify(errors[errors.length - 1]).includes(DEPTH_CODE),
      `${tag}: ${DEPTH_CODE} should be the last diagnostic`);
  }
  release_source(source);

  // Items completed before the limit stay in the tree; the item it was
  // hit in is dropped, so no consumer is handed a maximally deep stump.
  source = write_source('js', `first;\nsecond;\n${NESTED.arrays.gen(REJECT_LEVELS)}\nnever;\n`);
  result = await run(build.bin, ['parse', source.file, '--json', '--compact'], { stdout: true });
  if (expect_survived(result, `${tag} tree`)) {
    let body = null;
    try { body = JSON.parse(result.stdout).body; } catch (_) {}
    expect(Array.isArray(body) && body.length === 2,
      `${tag}: program.body should hold the two items before the deep one, got ${body && body.length}`);
  }
  release_source(source);

  // The limit counts nesting, not size: a long flat file is unaffected.
  source = write_source('js', rep('a;', 500000));
  result = await run(build.bin, ['parse', source.file, '--show-semantic-errors']);
  expect(result.status === 0, `${tag}: 500000 flat statements should parse`);
  release_source(source);

  // Each top-level item gets the full budget back.
  source = write_source('js', rep(NESTED.arrays.gen(400) + '\n', 50));
  result = await run(build.bin, ['parse', source.file, '--show-semantic-errors']);
  expect(result.status === 0, `${tag}: 50 items of depth 400 should parse`);
  release_source(source);

  // Nesting kinds combine against one budget: 300 + 300 levels is over.
  source = write_source('js', 'x=' + rep('[', 300) + rep('(', 300) + '1' + rep(')', 300) + rep(']', 300) + ';');
  result = await run(build.bin, ['parse', source.file]);
  expect(result.status === 1 && depth_errors(result.stderr) === 1, `${tag}: mixed nesting of 600 levels should be rejected`);
  release_source(source);

  // A chain link's own operands are still bounded: deep nesting hanging
  // off the middle of a long chain is rejected, and cleanly.
  source = write_source('js', `x=${CHAIN.plus(50000)}+${rep('[', 600)}${rep(']', 600)}+${CHAIN.plus(50000)};`);
  result = await run(build.bin, ['parse', source.file]);
  expect(result.status === 1 && depth_errors(result.stderr) === 1 && !result.signal,
    `${tag}: deep operand inside a long chain should be rejected`);
  release_source(source);

  // Deep nesting hanging off a long chain, within the limit, is walked by
  // every consumer: chain loops and bounded recursion compose.
  source = write_source('js',
    `x=${CHAIN.member(20000)}(${rep('[', 200)}${CHAIN.plus(20000)}${rep(']', 200)})${rep('.b(1)', 20000)};`);
  await run_all_tools(build, source, `${tag} chain+nesting`);
  release_source(source);
}

// ---------------------------------------------------------------------------

async function main() {
  const sections = {
    reject: section_reject, limit: section_limit, chains: section_chains,
    contexts: section_contexts, api: section_api,
  };
  for (const build of BUILDS) {
    if (!fs.existsSync(build.bin)) {
      console.error(`verify_depth_limit: missing ${path.relative(ROOT, build.bin)} (run task build / task build:debug)`);
      process.exit(1);
    }
  }
  const started = Date.now();
  for (const build of BUILDS) {
    for (const [name, section] of Object.entries(sections)) {
      if (ONLY.length > 0 && !ONLY.includes(name)) continue;
      const section_started = Date.now();
      const before = failures;
      await section(build);
      const status = failures === before ? 'ok' : `${failures - before} FAILED`;
      console.log(`  ${build.name.padEnd(7)} ${name.padEnd(8)} ${status} (${((Date.now() - section_started) / 1000).toFixed(1)}s)`);
    }
  }
  const seconds = ((Date.now() - started) / 1000).toFixed(1);
  if (failures > 0) {
    for (const line of failure_lines) console.error(`FAIL ${line}`);
    if (failures > failure_lines.length) console.error(`... and ${failures - failure_lines.length} more`);
    console.error(`verify_depth_limit: ${failures} of ${checks} checks failed in ${seconds}s (stack ${STACK_KB} KB)`);
    process.exit(1);
  }
  console.log(`verify_depth_limit: ${checks} checks passed in ${seconds}s (stack ${STACK_KB} KB, both builds)`);
}

main().catch(error => { console.error(error); process.exit(1); });
