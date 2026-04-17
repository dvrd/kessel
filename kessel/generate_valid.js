const fs = require('fs');

// Generate syntactically valid JavaScript test files
const sizes = [
  { name: 'tiny', lines: 10 },
  { name: 'small', lines: 100 },
  { name: 'medium', lines: 1000 },
  { name: 'large', lines: 10000 },
];

for (const { name, lines } of sizes) {
  let content = '// Generated valid JavaScript\n';
  content += 'const utils = { mul: (a, b) => a * b, add: (a, b) => a + b };\n';
  
  for (let i = 0; i < lines; i++) {
    content += `const v${i} = { n: ${i}, d: ${i} * 2, t: () => ${i} + 1 };\n`;
  }
  
  fs.writeFileSync(`valid_${name}.js`, content);
  const stats = fs.statSync(`valid_${name}.js`);
  console.log(`Created valid_${name}.js: ${lines} lines, ${stats.size} bytes`);
}

// Realistic file with various constructs
const realistic = `
function processData(items) {
  const results = [];
  for (const item of items) {
    if (item.active) {
      const transformed = { ...item, value: item.value * 2 };
      results.push(transformed);
    }
  }
  return results;
}

class DataProcessor {
  constructor(config) {
    this.config = config;
    this.cache = new Map();
  }
  
  async load(url) {
    try {
      const response = await fetch(url);
      const data = await response.json();
      this.cache.set(url, data);
      return data;
    } catch (err) {
      console.error('Failed to load:', err);
      return null;
    }
  }
  
  process(input) {
    const { type, data } = input;
    switch (type) {
      case 'number':
        return data.map(x => x * 2);
      case 'string':
        return data.map(s => s.toUpperCase());
      default:
        return data;
    }
  }
}

const arr = [1, 2, 3, 4, 5];
const doubled = arr.map(n => n * 2);
const evens = arr.filter(n => n % 2 === 0);
const sum = arr.reduce((a, b) => a + b, 0);

const obj = {
  name: "test",
  value: 42,
  items: arr,
  getTotal: () => sum,
  [Symbol.iterator]: function* () {
    for (const item of this.items) {
      yield item;
    }
  }
};

export { DataProcessor, processData, obj };
`;

fs.writeFileSync('valid_realistic.js', realistic.repeat(200));
const stats = fs.statSync('valid_realistic.js');
console.log(`Created valid_realistic.js: ${stats.size} bytes`);
