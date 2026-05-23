// Resolver entry for @dvrdlibs/kessel-linux-x64.
// Exports the absolute path to the platform-specific shared library.
// Loaded by the main @dvrdlibs/kessel package via require() on the
// sub-package name; npm only installs the sub-package whose os/cpu
// fields match the host, so only one resolves on any given machine.
'use strict';
module.exports = require('path').join(__dirname, 'libkessel.so');
