#!/usr/bin/env node
'use strict';
import { strict } from './strict.mjs';
console.log(strict(), (function () { return this; })());
