// Copyright 2026 the Kessel authors.  All rights reserved.
// This code is governed by the BSD license found in the LICENSE file.

/*---
esid: sec-module-semantics
description: Import and export syntax parses in module goal
flags: [module]
---*/

import { x } from './x.js';
export const y = x;
