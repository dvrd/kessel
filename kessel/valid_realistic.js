
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
