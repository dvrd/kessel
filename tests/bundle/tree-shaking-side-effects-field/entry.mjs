import { used } from 'pure-pkg';
import 'pure-pkg/unused-effect.js';
import { listed } from 'listed-pkg';
import 'impure-pkg';
console.log(used, listed);
