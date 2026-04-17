// Node.js EventEmitter pattern
const EventEmitter = require('events');

class DataStore extends EventEmitter {
  constructor() {
    super();
    this.data = new Map();
  }
  
  set(key, value) {
    this.data.set(key, value);
    this.emit('change', { key, value });
    this.emit(`change:${key}`, value);
  }
  
  get(key) {
    return this.data.get(key);
  }
}

const store = new DataStore();
store.on('change', evt => console.log('Changed:', evt));
