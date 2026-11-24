// Regression: a BigInt literal used as a property key had an empty source
// range. `({ 1n: x })` gave the key `start: 3, end: 3` because the end offset
// was read before the token was consumed, which yields the end of the token
// in front of the key. Object literals and class members shared the mistake;
// destructuring patterns were already right and are pinned here alongside.
//
// Every key below must span exactly its literal, as oxc-parser 0.127.0 reports.
({ 1n: x });
({ 0x10n() {}, get 2n() { return 1; }, set 3n(v) {}, async 4n() {}, *5n() {}, 6n  : y });
class A { 1n = 2; 3n() {} static 4n = 1; get 5n() { return 1; } static async *6n() {} }
const { 5n: p, 6n  : q } = w;
({ 7n: a, 8n: b = 1 } = c);
