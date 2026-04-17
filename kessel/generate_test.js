const fs = require('fs');

// Generate test files of different sizes
const sizes = [
  { name: 'tiny', lines: 10, size: '100B' },
  { name: 'small', lines: 100, size: '1KB' },
  { name: 'medium', lines: 1000, size: '10KB' },
  { name: 'large', lines: 10000, size: '100KB' },
];

const statement = 'const x = { a: 1, b: 2, c: () => { return x * 2; } };\n';

for (const { name, lines } of sizes) {
  let content = '// Generated test file\n';
  for (let i = 0; i < lines; i++) {
    content += `const var${i} = { n: ${i}, f: () => ${i} * 2 };\n`;
  }
  fs.writeFileSync(`bench_${name}.js`, content);
  const stats = fs.statSync(`bench_${name}.js`);
  console.log(`Created bench_${name}.js: ${lines} lines, ${stats.size} bytes`);
}

// Also create a realistic file with mixed constructs
const realistic = `
// Realistic JavaScript code
import { utils } from './utils';

export class Component {
  constructor(props) {
    this.props = props;
    this.state = { count: 0 };
  }
  
  render() {
    const { count } = this.state;
    return \`<div>\${count}</div>\`;
  }
  
  async fetchData() {
    try {
      const data = await fetch('/api/data');
      return await data.json();
    } catch (e) {
      console.error(e);
    }
  }
}

const arr = [1, 2, 3].map(x => x * 2);
const obj = { a: 1, ...this.props };
`;

fs.writeFileSync('bench_realistic.js', realistic.repeat(100));
const realStats = fs.statSync('bench_realistic.js');
console.log(`Created bench_realistic.js: ${realStats.size} bytes`);
