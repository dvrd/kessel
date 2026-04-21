// IIFE con diferentes formas
(function() { console.log('standard'); })();
(function() { console.log('standard2'); }());

(function named() { return named; })();

(() => { console.log('arrow IIFE'); })();

(async function() { await Promise.resolve(); })();

(function(global) { global.test = true; })(this);

!function() { console.log('negated'); }();
+function() { console.log('unary plus'); }();
void function() { console.log('void'); }();
