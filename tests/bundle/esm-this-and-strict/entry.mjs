import { topThis, arrowThis, isStrict } from './mod.mjs';
console.log(this, topThis, arrowThis(), isStrict());
const self = () => this;
console.log(self(), typeof this);
