const utils = {
  add: (a, b) => a + b,
  mul: (a, b) => a * b,
};

class Calculator {
  constructor() {
    this.history = [];
  }
  
  calculate(op, a, b) {
    let result;
    switch(op) {
      case 'add': result = utils.add(a, b); break;
      case 'mul': result = utils.mul(a, b); break;
    }
    this.history.push({ op, a, b, result });
    return result;
  }
}

const arr = [1, 2, 3].map(x => x * 2);
const evens = arr.filter(n => n % 2 === 0);
