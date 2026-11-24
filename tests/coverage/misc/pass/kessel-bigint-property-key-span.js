// A BigInt literal is a valid property key in object literals, class bodies and
// destructuring patterns. The span of each key is pinned by the golden
// tests/fixtures/regression/013_bigint_key_span.js; this copy keeps the shapes
// in the conformance museum.
({ 1n: x });
({ 0x10n() {}, get 2n() { return 1; }, set 3n(v) {}, async 4n() {}, *5n() {}, 6n  : y });
class A { 1n = 2; 3n() {} static 4n = 1; get 5n() { return 1; } static async *6n() {} }
const { 5n: p, 6n  : q } = w;
({ 7n: a, 8n: b = 1 } = c);
