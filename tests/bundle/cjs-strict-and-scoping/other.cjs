'use strict';
var shared = 'other-var';
function helper() { return 'other-helper'; }
var __commonJS = 'user binding named like a helper';
var require_other = 'user binding named like a wrapper';
exports.read = () => [shared, helper(), __commonJS.length, require_other.length].join(',');
