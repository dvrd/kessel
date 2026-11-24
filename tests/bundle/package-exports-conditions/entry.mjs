import main, { kind } from 'dual';
import { feature } from 'dual/feature';
import { internal } from 'dual/internal/thing.js';
import { viaCjs } from './via.cjs';
import self from 'scoped-app';
import { mapped } from '#mapped';
console.log(kind, main, feature, internal, viaCjs, self, mapped);
