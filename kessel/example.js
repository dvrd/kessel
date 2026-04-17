// Test file for Kessel parser

const PI = 3.14159;
let radius = 5;

function calculateArea(r) {
    return PI * r * r;
}

const area = calculateArea(radius);

if (area > 50) {
    console.log("Large circle");
} else {
    console.log("Small circle");
}

for (let i = 0; i < 10; i++) {
    console.log(i);
}

class Circle {
    constructor(r) {
        this.radius = r;
    }
    
    getArea() {
        return PI * this.radius * this.radius;
    }
    
    getCircumference() {
        return 2 * PI * this.radius;
    }
}

const circle = new Circle(10);
console.log(circle.getArea());

// Arrow functions
const double = x => x * 2;
const sum = (a, b) => a + b;

// Array destructuring
const [first, second, ...rest] = [1, 2, 3, 4, 5];

// Object destructuring
const { name, age } = { name: "Alice", age: 30 };

// Template literals
const message = `Hello, ${name}! You are ${age} years old.`;

// Spread operator
const arr1 = [1, 2, 3];
const arr2 = [...arr1, 4, 5, 6];

// Try-catch
try {
    riskyOperation();
} catch (error) {
    console.error("An error occurred:", error);
} finally {
    cleanup();
}

// Export
export { Circle, calculateArea };
export default Circle;
