#!/usr/bin/env node
// Class decorator binary-buffer gate (S26 W1).
//
// Walks the raw-transfer binary AST emitted by `kessel raw` for the
// stacked-feature fixture `tests/fixtures/spec/interactions/001_decorators_private_static_block.js`
// and asserts that:
//
//   * ClassDeclaration `id.name`           is rewritten to "A"
//   * Class-level `decorators[0].expression.name`         is "frozen"
//   * Per-method `decorators[0].expression.name` (`@bound value()`) is "bound"
//
// Before S26 W1 these strings were left as raw source pointers in the
// binary buffer and `c.decorators` / `elem.decorators` slots had
// dynamic-array headers with un-rewritten data ptrs. JSON output was
// already correct; the gap was silent.
//
// The kessel JSON output is used as the source of truth for the
// expected decorator names so the verifier survives any future change
// to the fixture (just re-run; expectations track the fixture).
//
// Hard-coded byte offsets within ClassExpression / ClassElement /
// Decorator come from the Odin layout (recapture via the layout-probe
// described in src/raw_transfer.odin's TODOs if the structs ever shift).

'use strict';

const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

const ROOT = path.resolve(__dirname, '../..');
const FIXTURE = path.join(ROOT, 'tests/fixtures/spec/interactions/001_decorators_private_static_block.js');
const KESSEL = path.join(ROOT, 'bin/kessel');
const OUT = '/tmp/_verify_class_decorators.bin';

if (!fs.existsSync(KESSEL)) {
	console.error(`kessel binary not found at ${KESSEL}; run \`task build\` first.`);
	process.exit(2);
}
if (!fs.existsSync(FIXTURE)) {
	console.error(`fixture missing: ${FIXTURE}`);
	process.exit(2);
}

// ----- Truth: kessel JSON output ----------------------------------------
// Drive expectations from the parser's own JSON path (which the existing
// gates already validate against OXC). This way the binary verifier is a
// JSON↔binary parity check, not an independent fixture transcription.

const jsonText = execSync(`${KESSEL} parse ${FIXTURE}`, { encoding: 'utf8' });
const ast = JSON.parse(jsonText);

function findClass(program) {
	for (const stmt of program.body) {
		if (stmt.type === 'ClassDeclaration') return stmt;
	}
	throw new Error('fixture changed: no ClassDeclaration at top level');
}
const cls = findClass(ast);
const classNameExpected = cls.id && cls.id.name;
const classDecoratorsExpected = (cls.decorators || []).map((d) => d.expression && d.expression.name);
let methodDecoratorsExpected = null;
for (const elem of cls.body.body) {
	const names = (elem.decorators || []).map((d) => d.expression && d.expression.name);
	if (names.length > 0) { methodDecoratorsExpected = { keyName: elem.key && elem.key.name, names }; break; }
}

if (classNameExpected !== 'A') {
	console.error(`fixture sanity: expected class name "A", got ${JSON.stringify(classNameExpected)}`);
	process.exit(2);
}
if (!(classDecoratorsExpected.length === 1 && classDecoratorsExpected[0] === 'frozen')) {
	console.error(`fixture sanity: expected class decorators [frozen], got ${JSON.stringify(classDecoratorsExpected)}`);
	process.exit(2);
}
if (!methodDecoratorsExpected || methodDecoratorsExpected.names[0] !== 'bound') {
	console.error(`fixture sanity: expected a method with [bound] decorator; got ${JSON.stringify(methodDecoratorsExpected)}`);
	process.exit(2);
}

// ----- Capture the raw binary buffer -----------------------------------
execSync(`${KESSEL} raw ${FIXTURE} --out ${OUT}`, { stdio: 'pipe' });
const bin = fs.readFileSync(OUT);
const HEADER = 20;
const MAGIC = 0x4B455353;
if (bin.readUInt32LE(0) !== MAGIC) { console.error('bad magic'); process.exit(1); }
const programOff = bin.readUInt32LE(8);
const buf = bin.subarray(HEADER);
const view = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
const source = fs.readFileSync(FIXTURE);

// ----- Binary readers ---------------------------------------------------
const STRING_ARENA_FLAG = 0x80000000;
function inBounds(off, n) { return off >= 0 && off + n <= buf.length; }
function u32(off) {
	if (!inBounds(off, 4)) throw new RangeError(`u32 read at ${off} out of buffer (len=${buf.length})`);
	return view.getUint32(off, true);
}
function u8(off) {
	if (!inBounds(off, 1)) throw new RangeError(`u8 read at ${off} out of buffer (len=${buf.length})`);
	return view.getUint8(off);
}
function dyn(off) { return { data: u32(off), len: u32(off + 4) }; }
function unionAt(off) { return { ptr: u32(off), tag: u8(off + 8) }; }
// safeArray: returns the dyn-header iff its data offset is sane (in-buffer
// and non-zero for non-empty arrays). The pre-fix path leaves rawptr bits
// in those slots, so the data offset tends to look enormous — reject and
// emit a clean FAIL rather than crash on out-of-bounds.
function safeArray(label, headerOff, slotSize) {
	const h = dyn(headerOff);
	if (h.len === 0) return h;
	const end = h.data + h.len * slotSize;
	if (!inBounds(h.data, h.len * slotSize)) {
		failed++;
		console.error(`  FAIL ${label}: dyn header looks unrewritten {data=${h.data}, len=${h.len}} (buf=${buf.length})`);
		return { data: 0, len: 0 };
	}
	return h;
}
function str(off) {
	const raw = u32(off), l = u32(off + 4);
	if (l === 0 || l >= 1e6) return '';
	if (raw & STRING_ARENA_FLAG) {
		const arenaOff = raw & 0x7fffffff;
		return buf.slice(arenaOff, arenaOff + l).toString('utf8');
	}
	return source.slice(raw, raw + l).toString('utf8');
}

// ----- Layout constants (mirror src/ast.odin) ---------------------------
// Re-capture these via /tmp/layout_probe.odin (see commit message) if
// ClassExpression / ClassElement / Decorator field order changes.
// Program layout: loc(16) + type-enum(8) → body dyn-header at +24.
const PROGRAM_BODY_OFF       = 24;
const STMT_UNION_SIZE        = 16;   // {ptr:8, tag:1, pad:7}
const STMT_TAG_CLASSDECL     = 21;
const EXPR_UNION_SIZE        = 16;
const EXPR_TAG_IDENTIFIER    = 9;

const CLASS_EXPR_ID_OFF      = 16;   // Maybe(BindingIdentifier)
const CLASS_EXPR_ID_NAME_OFF = CLASS_EXPR_ID_OFF + 16; // BI.name (after BI.loc)
const CLASS_EXPR_BODY_BODY_OFF = 80;   // body.body dyn-header
const CLASS_EXPR_DECORATORS_OFF = 120; // decorators dyn-header
const CLASS_ELEM_SIZE        = 112;
const CLASS_ELEM_KEY_OFF     = 16;   // ^Expression
const CLASS_ELEM_DECORATORS_OFF = 48;
const DECORATOR_SIZE         = 24;
const DECORATOR_EXPR_OFF     = 16;   // ^Expression
const IDENT_NAME_OFF         = 16;   // Identifier.name (after loc)

// ----- Walk Program → find ClassDeclaration ----------------------------
function findProgramOffset() { return programOff; }
const progBase = findProgramOffset();

function readProgramBody() {
	// Program layout: directives at 0 (dyn at +0), body dyn-header at +64.
	// We don't care about directives for this fixture; just walk body.
	return dyn(progBase + PROGRAM_BODY_OFF);
}
const progBody = readProgramBody();

function findClassDeclOffset() {
	for (let i = 0; i < progBody.len; i++) {
		const slotOff = progBody.data + i * 8;          // Program.body holds u32 slots after rewrite
		const slotPtr = u32(slotOff);
		if (slotPtr === 0) continue;
		const u = unionAt(slotPtr);                      // Statement union
		if (u.tag === STMT_TAG_CLASSDECL) return u.ptr;
	}
	return -1;
}
const classOff = findClassDeclOffset();
if (classOff < 0) {
	console.error('FAIL: no ClassDeclaration found in binary buffer');
	process.exit(1);
}

// ----- Assertions -------------------------------------------------------
let failed = 0;
// `failed` is referenced by safeArray defined above; declared at module scope
// before any call. Hoisted intentionally so the helpers can write to it.
function check(label, actual, expected) {
	if (actual === expected) {
		console.log(`  OK   ${label}: ${JSON.stringify(actual)}`);
	} else {
		failed++;
		console.error(`  FAIL ${label}: actual=${JSON.stringify(actual)} expected=${JSON.stringify(expected)}`);
	}
}

// 1. id.name
const idName = str(classOff + CLASS_EXPR_ID_NAME_OFF);
check('class.id.name', idName, classNameExpected);

// Helper: read the name from a Decorator entry's expression slot.
function decoratorName(decBase, idx) {
	const decEntry = decBase + idx * DECORATOR_SIZE;
	const exprUnionOff = u32(decEntry + DECORATOR_EXPR_OFF);
	if (exprUnionOff === 0) return null;
	const u = unionAt(exprUnionOff);
	if (u.tag !== EXPR_TAG_IDENTIFIER) return `<tag ${u.tag}>`;
	return str(u.ptr + IDENT_NAME_OFF);
}

// 2. class-level decorators
const classDecHeader = safeArray('class.decorators', classOff + CLASS_EXPR_DECORATORS_OFF, DECORATOR_SIZE);
check('class.decorators.len', classDecHeader.len, classDecoratorsExpected.length);
for (let i = 0; i < classDecHeader.len; i++) {
	check(`class.decorators[${i}].name`, decoratorName(classDecHeader.data, i), classDecoratorsExpected[i]);
}

// 3. find the method whose decorators[0] = "bound"
const bodyHeader = safeArray('class.body.body', classOff + CLASS_EXPR_BODY_BODY_OFF, CLASS_ELEM_SIZE);
let methodMatched = false;
for (let i = 0; i < bodyHeader.len; i++) {
	const elemOff = bodyHeader.data + i * CLASS_ELEM_SIZE;
	const elemDecHeader = safeArray(`class.body.body[${i}].decorators`, elemOff + CLASS_ELEM_DECORATORS_OFF, DECORATOR_SIZE);
	if (elemDecHeader.len === 0) continue;
	const first = decoratorName(elemDecHeader.data, 0);
	// match by first-decorator name to the JSON expectation
	if (first === methodDecoratorsExpected.names[0]) {
		methodMatched = true;
		// also verify the method's key.name matches what JSON saw
		const keyUnionOff = u32(elemOff + CLASS_ELEM_KEY_OFF);
		if (keyUnionOff !== 0) {
			const ku = unionAt(keyUnionOff);
			if (ku.tag === EXPR_TAG_IDENTIFIER) {
				check('method.key.name', str(ku.ptr + IDENT_NAME_OFF), methodDecoratorsExpected.keyName);
			}
		}
		check(`method.decorators[0].name`, first, methodDecoratorsExpected.names[0]);
		for (let d = 1; d < elemDecHeader.len; d++) {
			check(`method.decorators[${d}].name`, decoratorName(elemDecHeader.data, d), methodDecoratorsExpected.names[d]);
		}
		break;
	}
}
if (!methodMatched) {
	failed++;
	console.error('FAIL: no class element matched the JSON-side decorator expectation');
}

if (failed > 0) {
	console.error(`\n${failed} failure(s)`);
	process.exit(1);
}
console.log('\n✅ class+decorator binary buffer matches JSON expectations');
