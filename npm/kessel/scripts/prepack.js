#!/usr/bin/env node
/**
 * Pre-pack script: copies the platform binary into bin/ before npm pack.
 * For local development, the binary is resolved from ../../bin/libkessel.dylib.
 * For publishing, the CI builds each platform and places it in bin/.
 */

'use strict';
const fs = require('fs');
const path = require('path');

const platform = process.platform;
const arch = process.arch;
const ext = platform === 'darwin' ? 'dylib' : platform === 'win32' ? 'dll' : 'so';
const binDir = path.join(__dirname, '..', 'bin');
const target = path.join(binDir, `libkessel-${platform}-${arch}.${ext}`);

// If the target already exists (CI placed it), we're done.
if (fs.existsSync(target)) {
  console.log(`prepack: ${target} already exists`);
  process.exit(0);
}

// Try to copy from the project build directory
const source = path.resolve(__dirname, '../../../bin/libkessel.' + ext);
if (fs.existsSync(source)) {
  fs.mkdirSync(binDir, { recursive: true });
  fs.copyFileSync(source, target);
  console.log(`prepack: copied ${source} → ${target}`);
} else {
  console.warn(`prepack: WARNING — no binary found at ${source}`);
  console.warn(`         Run 'task build:lib' first.`);
}
