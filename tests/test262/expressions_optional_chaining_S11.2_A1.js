// Copyright 2026 the Kessel authors.  All rights reserved.
// This code is governed by the BSD license found in the LICENSE file.

/*---
esid: sec-optional-chaining-operator
description: Optional chaining expression parses in script goal
---*/

var value = obj?.nested?.call?.(1);
