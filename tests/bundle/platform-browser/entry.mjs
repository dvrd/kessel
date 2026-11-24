import { where } from 'universal';
import shim from 'has-browser-field';
import ignored from 'has-browser-field/server-only.js';
import { viaRequire } from './uses.cjs';
console.log(where, shim, JSON.stringify(ignored), viaRequire);
