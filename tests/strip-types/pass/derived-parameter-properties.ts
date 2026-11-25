const events: string[] = [];

class Base {
  constructor(public value: number) {
    "use strict";
    events.push("base:" + this.value);
  }
}

class Derived extends Base {
  constructor(override value: number, readonly label: string) {
    events.push("before-super");
    super(value + 1);

    class Nested extends Base {
      constructor(public inner: number) {
        super(inner + 2);
      }
    }

    const nested = new Nested(40);
    if (nested.value !== 42 || nested.inner !== 40) throw new Error("nested properties");
    if (this.value !== value || this.label !== label) throw new Error("derived properties");
  }
}

new Derived(5, "ok");
if (events.join(",") !== "before-super,base:6,base:42") throw new Error("constructor order");
