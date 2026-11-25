'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const binary = path.resolve(process.argv[2] || path.join(__dirname, '../../bin/kessel'));
const oracle = process.argv[3];
const folder = fs.mkdtempSync(path.join(os.tmpdir(), 'kessel-react-hooks-'));
// Each pair specifies the first diagnostic span on its line. An omitted span
// requires a clean line, including hooks after a labeled block or thrown render.
const placement = [
  ['function View(p){ if(p.ready) useEffect(refresh); }', 'useEffect(refresh)'],
  ['function useItems(){ for(const item of items) React.useMemo(item); }', 'React.useMemo(item)'],
  ['function Child(p){ if (!p) return null; useThing(); }', 'useThing()'],
  ['function Load(p){ if(p) React.use(data); }'],
  ['function Show(){ outer: { if(skip) break outer; useItem(); } useNext(); }', 'useItem()'],
  ['function Render(){ if(!ok){ throw failure; } else { useState(); } }'],
  ['function Handle(){ try { useRecord(); } catch {} }', 'useRecord()'],
  ['function Finish(){ try { useRecord(); } finally { clean(); } }'],
  ['const AsyncView = async () => { useState(); };', 'async () => { useState(); }'],
  ['update = () => useState();', 'useState'],
  ['const {read = () => useState()} = api;', 'useState'],
  ['({read = () => useState()} = api);'],
  ['function Component(){ items.map(() => useState()); }', 'useState()'],
  ['const Wrapped = React.memo(() => useState());'],
  ['function Page(){ if(loading) helpers.useThing(); }'],
  ['function Options(x){ x ||= useOptions(); }', 'useOptions()'],
  ['function Toggle(x){ x &&= useToggle(); }', 'useToggle()'],
  ['function Fallback(x){ x ??= useFallback(); }', 'useFallback()'],
  ['function Add(x){ x += useAmount(); }'],
  ['class Panel { render(){ return useState(); } }', 'useState()'],
];

const dependencies = [
  ['function Capture(p){ return useMemo(()=>p.deep.key, []); }', '[]'],
  ['function Parent(p){ return useMemo(()=>p.deep.key, [p]); }'],
  ['function Optional(p){ return useMemo(()=>p.deep?.key, [p.deep]); }'],
  ['function Method(p){ React.useEffect(()=>p.user.refresh(), [p.user]); }'],
  ['function Dynamic(p,key){ useEffect(()=>p[key], [p,key]); }'],
  ['function Local(p){ useEffect(()=>{ const p={id:1}; log(p.id); }, []); }'],
  ['function Primitive(){ const value="fixed"; useEffect(()=>log(value), []); }'],
  ['function Setters(){ const [,set]=useState(0); React.useEffect(()=>set(1), []); }'],
  ['function Stable(){ function work(){ publish(42); } useEffect(()=>work(), []); }'],
  ['function Named(p){ function work(){ send(p); } useEffect(work, [p]); }'],
  ['function Pattern(p){ useEffect(()=>{ const {name}=p; send(name); }, [p.name]); }'],
  ['function Custom(p){ useExternalEffect(()=>publish(p.id), [p]); }'],
  ['function Handle(ref,p){ useImperativeHandle(ref, ()=>p.api, [p]); }'],
  ['function Required(){ return useMemo(()=>42); }', 'useMemo(()=>42)'],
  ['function Async(){ useEffect(async ()=>load(), []); }', 'async ()=>load()'],
  ['function Missing(){ React.useEffect(); }', 'React.useEffect()'],
  ['function Unstable(){ const unique=flag ? null : {}; useMemo(()=>unique, [unique]); }', 'unique', 'last'],
  ['function Unknown(){ useEffect(load(), []); }', 'useEffect'],
  ['function State(){ const [,set]=useState(0); useEffect(()=>get().then(set)); }', 'useEffect'],
  ['function Cleanup(){ const ref=useRef(); useEffect(()=>{ return ()=>ref.current.close(); }, []); }', 'ref.current'],
  ['function Owned(){ const ref=useRef(); useEffect(()=>{ ref.current=make(); return ()=>ref.current.close(); }, []); }'],
  ['function TypeOnly(value){ useEffect(()=>{ let typed: typeof value; }, []); }'],
  ['function CustomMissing(p){ useExternalEffect(()=>send(p), []); }', '[]'],
  ['function NotCustom(p){ useExternalEffectExtra(()=>send(p), []); }'],
];

function verify(rule, cases, setting) {
  const source = cases.map(([line]) => line).join('\n');
  fs.writeFileSync(path.join(folder, 'view.tsx'), source);
  fs.writeFileSync(path.join(folder, '.oxlintrc.json'), JSON.stringify({
    plugins: ['react'], rules: { ['react/' + rule]: setting },
  }));
  const expected = cases.flatMap(([line, mark, occurrence], index) => mark
    ? [[index + 1, (occurrence === 'last' ? line.lastIndexOf(mark) : line.indexOf(mark)) + 1, mark.length]] : []);
  for (const engine of [binary, oracle].filter(Boolean)) {
    const args = engine === binary ? ['lint', '--format=json'] : ['--format=json'];
    const result = spawnSync(engine, [...args, 'view.tsx'], { cwd: folder, encoding: 'utf8' });
    assert.ok([0, 1].includes(result.status), result.stderr || String(result.error));
    const actual = engine === binary
      ? JSON.parse(result.stderr)[0].messages.filter(m => m.ruleId === rule)
        .map(m => [m.line, m.column, m.endColumn - m.column])
      : JSON.parse(result.stdout).diagnostics.filter(d => d.code?.endsWith('(' + rule + ')'))
        .map(d => {
          const label = rule === 'exhaustive-deps' && /has (a missing dependency|missing dependencies):/.test(d.message)
            ? d.labels.at(-1) : d.labels[0];
          const { line, column, length } = label.span;
          return [line, column, length];
        });
    assert.deepEqual(actual.sort((a, b) => a[0] - b[0]), expected, engine);
  }
  console.log(rule + ' matched the expected spans on ' + cases.length + ' cases.');
}

function verifyDependencyFixes() {
  const file = path.join(folder, 'view.tsx');
  const flags = ['--fix-suggestions', '--fix-dangerously'];
  const source = (body, list, hook = 'useEffect') => 'function View(p, q, cb){ ' + hook + '(' + body + ', ' + list + '); }';
  const effect = '()=>send(p.user?.id, q)';
  const cases = [
    [effect, '[]', '[p.user?.id, q]'],
    [effect, '[ /* empty */ ]', '[ /* empty */ p.user?.id, q]'],
    [effect, '[q /* keep */]', '[q /* keep */, p.user?.id]'],
    [effect, '[q, /* keep */]', '[q, /* keep */p.user?.id]'],
    [effect, '[q,]', '[q, p.user?.id]'],
    [effect, '[q // keep\n]', '[q // keep\n, p.user?.id]'],
    [effect, '[,q]', '[,q, p.user?.id]'],
    ['()=>{const {name}=p;send(name)}', '[]', '[p.name]'],
    ['()=>{if(p.user) send(p.user.id)}', '[]', '[p.user]'],
    ['cb', '[]', '[cb]'],
    ['cb', '[p][q]', '[p][q]'],
    ['()=>{send(p);\n// eslint-disable-next-line react/exhaustive-deps\n}', '[]', '[]'],
    ['()=>send(p)', '[p, p]', '[p]'],
    ['()=>send(p)', '[unknown,p]', '[p]'],
    ['()=>send(p)', '[p, /* keep */ unknown]', '[p /* keep */ ]'],
    ['()=>send(p)', '[unknown /* keep */,p]', '[ /* keep */p]'],
    ['()=>send(p)', '[,p,p]', '[,p]'],
    ['()=>send(p)', '[p,,unknown]', '[p,,]'],
    ['()=>send(p)', '[p, q]', '[p]', 'useMemo'],
    ['()=>send(p)', '[q, p, p, unknown]', '[ p]', 'useMemo'],
    ['()=>send(q.id,p.user)', '[]', '[q.id, p.user]'],
  ];
  function run(modes, expected) {
    const result = spawnSync(binary, ['lint', '--format=json', ...modes, 'view.tsx'], { cwd: folder, encoding: 'utf8' });
    assert.ok([0, 1].includes(result.status), result.stderr || String(result.error));
    const messages = JSON.parse(result.stderr)[0].messages;
    assert.ok(messages.every(message => !message.fatal), result.stderr);
    assert.equal(fs.readFileSync(file, 'utf8'), expected);
    return messages;
  }
  const edits = cases.map(([body, before, after, hook]) => [source(body, before, hook), source(body, after, hook)]);
  for (const [input, expected] of [
    ['useMemo(()=>3)', 'useMemo(()=>3, [])'],
    ['useCallback(()=>p)', 'useCallback(()=>p, [p])'],
    ['useMemo(()=>p.user?.id, /* keep */)', 'useMemo(()=>p.user?.id, /* keep */[p.user?.id])'],
    ['useCallback((()=>p),)', 'useCallback((()=>p), [p])'],
    ['useMemo(cb)', 'useMemo(cb)'],
    ['useEffect(()=>p)', 'useEffect(()=>p)'],
  ]) {
    const view = call => 'function View(p,cb){ return ' + call + '; }';
    edits.push([view(input), view(expected)]);
  }
  for (const [input, expected] of edits) {
    fs.writeFileSync(file, input);
    for (const modes of [['--fix'], [flags[0]], [flags[1]]]) run(modes, input);
    const messages = run(flags, expected);
    if (input !== expected) assert.ok(messages.every(m => m.ruleId !== 'exhaustive-deps'));
    run(flags, expected);
  }
  console.log('Hook dependency fixes passed ' + edits.length + ' mode, preservation and repeat-run cases.');
}

function verifyPluginDefaults() {
  const file = 'defaults.tsx';
  fs.writeFileSync(path.join(folder, file), 'function View(p){if(p.ready) useEffect(()=>send(p.id), []);return null;}');
  const write = (name, config) => fs.writeFileSync(path.join(folder, name), JSON.stringify(config));
  write('base.json', { plugins: ['react'], categories: { pedantic: 'error' } });
  write('categories.json', { categories: { correctness: 'off', pedantic: 'warn' } });
  const deps = 'exhaustive-deps', hooks = 'rules-of-hooks';
  const cases = [
    [{}, []],
    ...['react', 'react-hooks', 'eslint-plugin-react', 'eslint-plugin-react-hooks'].map(plugin =>
      [{ plugins: [plugin] }, [[deps, 1]]]),
    [{ plugins: ['react'], categories: { correctness: 'allow' } }, []],
    [{ plugins: ['react'], categories: { correctness: 2, pedantic: 1 } }, [[deps, 2], [hooks, 1]]],
    [{ plugins: ['react'], categories: { pedantic: 'deny' }, rules: { 'react/rules-of-hooks': 'off' } }, [[deps, 1]]],
    [{ extends: ['base.json'], plugins: [] }, [[deps, 1], [hooks, 2]]],
    [{ extends: ['base.json'], categories: { correctness: 'off' } }, [[hooks, 2]]],
    [{ extends: ['categories.json'], plugins: ['react'] }, [[hooks, 1]]],
    [{ overrides: [{ files: ['*.tsx'], plugins: ['react'] }] }, [[deps, 1]]],
    [{ overrides: [{ files: ['*.js'], plugins: ['react'] }] }, []],
    [{ plugins: ['react'], overrides: [{ files: ['*.tsx'], plugins: [], rules: { 'react/exhaustive-deps': 'error' } }] }, [[deps, 2]]],
    [{ overrides: [{ files: ['*.tsx'], plugins: ['react'], rules: { 'react/rules-of-hooks': 'error' } }] }, [[deps, 1], [hooks, 2]]],
  ];
  for (const [config, expected] of cases) {
    write('.oxlintrc.json', config);
    for (const engine of [binary, oracle].filter(Boolean)) {
      const args = engine === binary ? ['lint', '--format=json', file] : ['--format=json', file];
      const r = spawnSync(engine, args, { cwd: folder, encoding: 'utf8' });
      assert.ok([0, 1].includes(r.status), r.stderr || String(r.error));
      const actual = engine === binary
        ? JSON.parse(r.stderr)[0].messages.map(m => [m.ruleId, m.severity])
        : JSON.parse(r.stdout).diagnostics.map(m => [m.code?.split('(').at(-1)?.replace(')', ''), m.severity === 'warning' ? 1 : 2]);
      assert.deepEqual(actual.filter(([rule]) => rule === deps || rule === hooks).sort(), expected, JSON.stringify(config));
    }
  }
  console.log('React plugin activation and category defaults passed ' + cases.length + ' project configurations.');
}

try {
  verify('rules-of-hooks', placement, 'warn');
  verify('exhaustive-deps', dependencies, ['warn', { additionalHooks: '^useExternalEffect$' }]);
  verifyDependencyFixes();
  verifyPluginDefaults();
} finally {
  fs.rmSync(folder, { recursive: true, force: true });
}
