#!/usr/bin/env node
const fs = require('fs');
const path = require('path');

const outDir = path.resolve(__dirname, '../bench/generated/structural');
fs.mkdirSync(outDir, { recursive: true });

function repeatLines(factory, count) {
  let out = '';
  for (let i = 0; i < count; i++) out += factory(i);
  return out;
}

const files = {
  'expr-heavy.js': repeatLines(i => `const v${i} = ${i} + ${i+1} * ${i+2} - (${i+3} / (${i+4} + 1)) ** 2 ?? ${i+5};\n`, 4500),
  'member-chain-heavy.js': repeatLines(i => `const v${i} = root.a${i%10}.b${(i+1)%10}.c${(i+2)%10}[idx${i%7}]?.d${(i+3)%10}?.e${(i+4)%10}(${i}, ${i+1}, ${i+2});\n`, 3200),
  'object-heavy.js': repeatLines(i => `const obj${i} = {a:${i}, b:${i+1}, c:${i+2}, d:${i+3}, e:${i+4}, f:${i+5}, g:${i+6}, h:${i+7}, nested:{x:${i}, y:${i+1}, z:${i+2}}, method(){ return this.a + this.b + this.c; }};\n`, 2200),
  'class-heavy.js': repeatLines(i => `class C${i} extends Base${i%5} { constructor(v){ super(v); this.v=v; } m${i%9}(a,b){ return a + b + this.v; } static s${i%7}(x){ return x * 2; } get g${i%5}(){ return this.v; } set g${i%5}(v){ this.v = v; } }\n`, 1500),
  'string-heavy.js': repeatLines(i => `const s${i} = \`prefix-${i}-\\n-${i+1}-\\u{1F600}-\\t-${i+2}-${'x'.repeat(24)}-${'y'.repeat(24)}\`;\n`, 3200),
  'destructuring-heavy.js': repeatLines(i => `const {a${i}: aa${i}, b${i}: {c${i}: cc${i}, d${i}: dd${i}}} = source${i%9}; const [x${i}, , y${i}, ...tail${i}] = arr${i%11};\n`, 2600),
};

for (const [name, content] of Object.entries(files)) {
  const full = path.join(outDir, name);
  fs.writeFileSync(full, content);
  console.log(`${name}\t${Buffer.byteLength(content)} bytes`);
}
