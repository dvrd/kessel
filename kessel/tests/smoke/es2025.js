// ES2025 Feature Test Suite

// 1. Template Literals
const name = "world";
const greeting = `Hello, ${name}!`;
const tagged = sql`SELECT * FROM users WHERE id = ${id}`;

// 2. Object Spread
const obj1 = { a: 1, b: 2 };
const obj2 = { ...obj1, c: 3 };
const obj3 = { ...obj1, ...obj2 };

// 3. Array Spread
const arr1 = [1, 2, 3];
const arr2 = [...arr1, 4, 5];

// 4. Destructuring - Array
const [x, y, z] = arr1;
const [first, ...rest] = arr1;

// 5. Destructuring - Object
const { a, b } = obj1;
const { a: renamed, c = 3 } = obj1;

// 6. Nested Destructuring
const nested = { user: { name: "John", age: 30 } };
const { user: { name: userName } } = nested;

// 7. Optional Chaining
const maybe = obj1?.prop?.nested;
const arrMaybe = arr1?.[0];
const funcMaybe = obj1?.method?.();

// 8. Nullish Coalescing
const value = null ?? "default";
const value2 = undefined ?? "default";
const value3 = 0 ?? "default"; // Should be 0, not "default"

// 9. Logical Assignment
let x1 = 0;
x1 ||= 5;
x1 &&= 3;
x1 ??= 10;

// 10. BigInt
const big = 9007199254740991n;
const bigHex = 0x1fffffffffffffn;
const bigBin = 0b11111111111111111111111111111111111111111111111111111n;

// 11. Async/Await
async function fetchData() {
    const data = await fetch('/api');
    return data;
}

// 12. Async Arrow Function
const asyncFn = async () => {
    await new Promise(resolve => setTimeout(resolve, 100));
};

// 13. For-await-of
async function* gen() {
    yield 1;
    yield 2;
}

async function consume() {
    for await (const val of gen()) {
        console.log(val);
    }
}

// 14. Class Fields
class MyClass {
    // Public fields
    publicField = 42;
    
    // Private fields
    #privateField = 'secret';
    
    // Static fields
    static staticField = 100;
    
    // Static private fields
    static #staticPrivate = 200;
    
    // Getter/Setter
    get value() {
        return this.publicField;
    }
    
    set value(v) {
        this.publicField = v;
    }
    
    // Private method
    #privateMethod() {
        return this.#privateField;
    }
    
    // Static block
    static {
        console.log('Class initialized');
    }
}

// 15. Dynamic Import
const module = await import('./module.js');

// 16. Top-level await (modules)
await Promise.resolve();

// 17. import.meta
const url = import.meta.url;

// 18. Class Heritage with expression
class Derived extends (getBaseClass()) {
    constructor() {
        super();
    }
}

// 19. New Error cause
throw new Error('Failed', { cause: originalError });

// 20. Object.hasOwn
const hasProp = Object.hasOwn(obj1, 'a');
