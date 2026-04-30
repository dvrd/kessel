#!/usr/bin/env node
// Class TypeScript binary-buffer gate (S26 W2-alt).
//
// Walks the raw-transfer binary AST emitted by `kessel raw --lang=ts` for
// the curated TS fixtures and asserts that the new TS-slot rewrites land
// where the JSON path says they should:
//
//   tests/fixtures/spec/typescript/002_generic_class.js
//     * c.type_parameters → TSTypeParameterDeclaration with one parameter
//       named "T"
//     * elem.type_annotation on the `value: T` field → TSTypeAnnotation
//       wrapping a TSTypeReference whose type_name resolves to "T"
//     * f.return_type on the `get(): T` method → TSTypeAnnotation wrapping
//       a TSTypeReference whose type_name resolves to "T"
//     * f.params[0].pattern.<Identifier>.type_annotation on the
//       constructor `(v: T)` parameter → same shape
//
//   tests/fixtures/spec/typescript/013_class_implements.js
//     * c.implements length matches JSON (covers single + multi-implements)
//     * each implements[i].expression.name matches JSON
//
// Before S26 W2-alt the binary buffer left every TS slot un-rewritten;
// rewrite_class_expression / rewrite_function_expression / rewrite_arrow
// now feed into a master rewrite_ts_type walker. Red before the fix, green
// after — verified by stashing rewrite_ts_type and re-running.
//
// Hard-coded byte offsets come from the same Odin layout-probe pattern
// used by verify_class_decorators.js. If any of the structs below shift,
// rerun the probe and update the constants.

'use strict';

const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

const ROOT = path.resolve(__dirname, '../..');
const KESSEL = path.join(ROOT, 'bin/kessel');
const FIXTURE_GENERIC = path.join(ROOT, 'tests/fixtures/spec/typescript/002_generic_class.js');
const FIXTURE_IMPL    = path.join(ROOT, 'tests/fixtures/spec/typescript/013_class_implements.js');

if (!fs.existsSync(KESSEL)) {
	console.error(`kessel binary not found at ${KESSEL}; run \`task build\` first.`);
	process.exit(2);
}

let failed = 0;
function check(label, actual, expected) {
	if (actual === expected) {
		console.log(`  OK   ${label}: ${JSON.stringify(actual)}`);
	} else {
		failed++;
		console.error(`  FAIL ${label}: actual=${JSON.stringify(actual)} expected=${JSON.stringify(expected)}`);
	}
}

// ----- Layout constants (mirror src/ast.odin) ---------------------------
// Re-capture these via /tmp/layout_probe3.odin if any struct shifts.
const HEADER = 20;
const STMT_TAG_CLASSDECL     = 21;
const EXPR_TAG_IDENTIFIER    = 9;
// TSType union — keywords 1..14, compounds 15..36
const TSTYPE_TAG_TYPEREF     = 15;

const PROGRAM_BODY_OFF       = 24;

// ClassExpression layout (size 216).
const CE_ID_OFF              = 16;
const CE_ID_NAME_OFF         = CE_ID_OFF + 16;
const CE_TYPE_PARAMS_OFF     = 160;  // Maybe(^TSTypeParameterDeclaration)
const CE_BODY_BODY_OFF       = 80;   // body.body dyn-header
const CE_IMPLEMENTS_OFF      = 168;  // [dynamic]TSInterfaceHeritage

// ClassElement layout (size 112).
const CE_ELEM_SIZE           = 112;
const CE_ELEM_KEY_OFF        = 16;
const CE_ELEM_VALUE_OFF      = 24;   // Maybe(^Expression)
const CE_ELEM_TYPE_ANNOT_OFF = 96;   // Maybe(^TSTypeAnnotation)

// TSTypeParameterDeclaration layout (size 56).
const TSTPD_PARAMS_OFF       = 16;   // dyn-header
// TSTypeParameter layout (size 72).
const TSTP_SIZE              = 72;
const TSTP_NAME_NAME_OFF     = 32;   // BindingIdentifier.name string

// TSTypeAnnotation layout (size 24).
const TSTA_TYPE_ANNOT_OFF    = 16;   // ^TSType (union ptr)

// TSTypeReference layout (size 32).
const TSTR_TYPE_NAME_OFF     = 16;   // ^Expression

// TSInterfaceHeritage value layout (size 32).
const TSIH_SIZE              = 32;
const TSIH_EXPRESSION_OFF    = 16;   // ^Expression

// FunctionExpression layout (size 224).
const FE_PARAMS_OFF          = 56;   // [dynamic]FunctionParameter
const FE_RETURN_TYPE_OFF     = 208;  // Maybe(^TSTypeAnnotation)
// FunctionParameter layout (size 48). loc(16) + pattern(16) + default_val(8) + flags(8).
const FP_SIZE                = 48;
const FP_PATTERN_OFF         = 16;   // Pattern union {ptr:8, tag:1, pad:7}

// Identifier layout: loc(16) + name string(16) + type_annotation Maybe(8) ...
const IDENT_NAME_OFF         = 16;
const IDENT_TYPE_ANNOT_OFF   = 32;   // Maybe(^TSTypeAnnotation)

// ----- Per-fixture verification ----------------------------------------
function verify(fixtureAbs, label) {
	const jsonText = execSync(`${KESSEL} parse ${fixtureAbs} --lang=ts`, { encoding: 'utf8' });
	const ast = JSON.parse(jsonText);

	const outBin = `/tmp/_verify_class_typescript_${path.basename(fixtureAbs, '.js')}.bin`;
	execSync(`${KESSEL} raw ${fixtureAbs} --lang=ts --out ${outBin}`, { stdio: 'pipe' });
	const bin = fs.readFileSync(outBin);
	if (bin.readUInt32LE(0) !== 0x4B455353) { console.error('bad magic'); process.exit(1); }
	const programOff = bin.readUInt32LE(8);
	const buf = bin.subarray(HEADER);
	const view = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
	const source = fs.readFileSync(fixtureAbs);

	const STRING_ARENA_FLAG = 0x80000000;
	function inBounds(off, n) { return off >= 0 && off + n <= buf.length; }
	function u32(off) {
		if (!inBounds(off, 4)) throw new RangeError(`u32 read at ${off} out of buffer`);
		return view.getUint32(off, true);
	}
	function u8(off) { return view.getUint8(off); }
	function dyn(off) { return { data: u32(off), len: u32(off + 4) }; }
	function unionAt(off) { return { ptr: u32(off), tag: u8(off + 8) }; }
	function str(off) {
		const raw = u32(off), l = u32(off + 4);
		if (l === 0 || l >= 1e6) return '';
		if (raw & STRING_ARENA_FLAG) {
			const arenaOff = raw & 0x7fffffff;
			return buf.slice(arenaOff, arenaOff + l).toString('utf8');
		}
		return source.slice(raw, raw + l).toString('utf8');
	}
	function safeArray(lab, headerOff, slotSize) {
		const h = dyn(headerOff);
		if (h.len === 0) return h;
		if (!inBounds(h.data, h.len * slotSize)) {
			failed++;
			console.error(`  FAIL ${label} ${lab}: dyn header looks unrewritten {data=${h.data}, len=${h.len}}`);
			return { data: 0, len: 0 };
		}
		return h;
	}
	// Treats a Maybe(^T) field as "set" only when the offset is non-zero AND
	// inside the buffer — catches the unrewritten-ptr case where bytes look
	// like a giant out-of-range arena address.
	function maybePtrSet(lab, fieldAddr, expectedSet) {
		const v = u32(fieldAddr);
		const inside = v > 0 && v < buf.length;
		if (expectedSet && !inside) {
			failed++;
			console.error(`  FAIL ${label} ${lab}: Maybe ptr ${v} (buf=${buf.length}) — looks unrewritten`);
			return 0;
		}
		if (!expectedSet && inside) {
			failed++;
			console.error(`  FAIL ${label} ${lab}: expected nil, got in-buffer offset ${v}`);
			return 0;
		}
		return inside ? v : 0;
	}
	// Two-step deref: a `^TSType` field holds the offset of the TSType
	// union value; the union value at that offset has the rewritten inner
	// ptr at +0 and the variant tag at +8.
	function derefTsType(fieldAddr) {
		const unionOff = u32(fieldAddr);
		if (unionOff === 0) return null;
		return unionAt(unionOff);
	}
	// Read an Identifier name string given a union ptr to the Identifier
	// inside an Expression slot.
	function readExprIdentName(exprUnionPtr) {
		const u = unionAt(exprUnionPtr);
		if (u.tag !== EXPR_TAG_IDENTIFIER) return `<expr tag ${u.tag}>`;
		return str(u.ptr + IDENT_NAME_OFF);
	}

	// Walk Program.body to find the ClassDeclaration.
	const progBody = dyn(programOff + PROGRAM_BODY_OFF);
	let classOff = -1, jsonClass = null;
	for (let i = 0; i < progBody.len; i++) {
		const slotPtr = u32(progBody.data + i * 8);
		if (slotPtr === 0) continue;
		const u = unionAt(slotPtr);
		if (u.tag === STMT_TAG_CLASSDECL) {
			classOff = u.ptr;
			jsonClass = ast.body[i];
			break;
		}
	}
	if (classOff < 0) { failed++; console.error(`  FAIL ${label}: no ClassDeclaration`); return; }

	return { buf, view, u32, u8, dyn, unionAt, str, safeArray, maybePtrSet, readExprIdentName, derefTsType, classOff, jsonClass, ast, programOff };
}

// Wrap the per-fixture body in a try so a stray RangeError (e.g. an
// unrewritten pointer the safety nets didn't catch) shows up as a clean
// FAIL with the failing label, not a Node stack-trace crash.
function safely(label, fn) {
	try { fn(); } catch (e) {
		failed++;
		console.error(`  FAIL ${label}: ${e.message}`);
	}
}

// =====================================================================
// Fixture 1 — 002_generic_class.js: type_params + field/return type
// =====================================================================
safely('002_generic', () => {
	const ctx = verify(FIXTURE_GENERIC, '002_generic');
	if (ctx) {
		const { u32, dyn, unionAt, str, safeArray, maybePtrSet, readExprIdentName, derefTsType, classOff, jsonClass } = ctx;

		// 1. c.type_parameters → params[0].name == "T"
		const tpdPtr = maybePtrSet('002 c.type_parameters', classOff + CE_TYPE_PARAMS_OFF, true);
		if (tpdPtr !== 0) {
			const tpdParams = safeArray('002 c.type_parameters.params', tpdPtr + TSTPD_PARAMS_OFF, TSTP_SIZE);
			const expectedTpdLen = (jsonClass.typeParameters && jsonClass.typeParameters.params.length) || 0;
			check('002 c.type_parameters.params.len', tpdParams.len, expectedTpdLen);
			if (tpdParams.len > 0) {
				const expectedName = jsonClass.typeParameters.params[0].name.name;
				check('002 c.type_parameters.params[0].name', str(tpdParams.data + TSTP_NAME_NAME_OFF), expectedName);
			}
		}

		// 2. Walk class body — find the field `value: T` and assert its
		//    type_annotation resolves through TSTypeAnnotation → TSTypeReference → "T".
		const bodyHeader = safeArray('002 c.body.body', classOff + CE_BODY_BODY_OFF, CE_ELEM_SIZE);
		let fieldChecked = false, methodChecked = false, ctorChecked = false;
		for (let i = 0; i < bodyHeader.len; i++) {
			const elemOff = bodyHeader.data + i * CE_ELEM_SIZE;
			const keyUnionOff = u32(elemOff + CE_ELEM_KEY_OFF);
			if (keyUnionOff === 0) continue;
			const keyName = readExprIdentName(keyUnionOff);
			const jsonElem = jsonClass.body.body.find((e) => e.key && e.key.name === keyName);
			if (!jsonElem) continue;

			// Field `value: T` — PropertyDefinition with typeAnnotation set.
			if (keyName === 'value') {
				const taPtr = maybePtrSet('002 elem(value).type_annotation', elemOff + CE_ELEM_TYPE_ANNOT_OFF, true);
				if (taPtr !== 0) {
					const innerTsType = derefTsType(taPtr + TSTA_TYPE_ANNOT_OFF);
					check('002 elem(value).type_annotation→TSTypeReference', innerTsType && innerTsType.tag, TSTYPE_TAG_TYPEREF);
					if (innerTsType && innerTsType.tag === TSTYPE_TAG_TYPEREF) {
						const tnUnion = u32(innerTsType.ptr + TSTR_TYPE_NAME_OFF);
						check('002 elem(value).type_annotation.type_name', readExprIdentName(tnUnion), 'T');
					}
				}
				fieldChecked = true;
			}

			// Method `get(): T` — MethodDefinition; value is FunctionExpression
			// whose return_type points at TSTypeAnnotation → TSTypeReference → "T".
			if (keyName === 'get') {
				const valuePtr = u32(elemOff + CE_ELEM_VALUE_OFF);
				if (valuePtr !== 0) {
					const valueUnion = unionAt(valuePtr);
					const fnOff = valueUnion.ptr;
					const rtPtr = maybePtrSet('002 elem(get).f.return_type', fnOff + FE_RETURN_TYPE_OFF, true);
					if (rtPtr !== 0) {
						const innerTsType = derefTsType(rtPtr + TSTA_TYPE_ANNOT_OFF);
						check('002 elem(get).f.return_type→TSTypeReference', innerTsType && innerTsType.tag, TSTYPE_TAG_TYPEREF);
						if (innerTsType && innerTsType.tag === TSTYPE_TAG_TYPEREF) {
							const tnUnion = u32(innerTsType.ptr + TSTR_TYPE_NAME_OFF);
							check('002 elem(get).f.return_type.type_name', readExprIdentName(tnUnion), 'T');
						}
					}
				}
				methodChecked = true;
			}

			// Constructor `(v: T)` — params[0].pattern is a Pattern union holding
			// ^Identifier; that Identifier's `type_annotation` Maybe pointer must
			// resolve through TSTypeAnnotation → TSTypeReference → "T".
			if (keyName === 'constructor') {
				const valuePtr = u32(elemOff + CE_ELEM_VALUE_OFF);
				if (valuePtr !== 0) {
					const valueUnion = unionAt(valuePtr);
					const fnOff = valueUnion.ptr;
					const params = safeArray('002 ctor.f.params', fnOff + FE_PARAMS_OFF, FP_SIZE);
					if (params.len > 0) {
						const fpOff = params.data;
						// Pattern union value is INLINE in FunctionParameter at
						// offset 16 (after loc). Pattern union variant tag 1 =
						// ^Identifier per src/ast.odin's Pattern decl.
						const patternUnion = unionAt(fpOff + FP_PATTERN_OFF);
						check('002 ctor.f.params[0].pattern tag (1=Identifier)', patternUnion.tag, 1);
						const identTaPtr = maybePtrSet('002 ctor.f.params[0].id.type_annotation', patternUnion.ptr + IDENT_TYPE_ANNOT_OFF, true);
						if (identTaPtr !== 0) {
							const innerTsType = derefTsType(identTaPtr + TSTA_TYPE_ANNOT_OFF);
							check('002 ctor.f.params[0].id.type_annotation→TSTypeReference', innerTsType && innerTsType.tag, TSTYPE_TAG_TYPEREF);
							if (innerTsType && innerTsType.tag === TSTYPE_TAG_TYPEREF) {
								const tnUnion = u32(innerTsType.ptr + TSTR_TYPE_NAME_OFF);
								check('002 ctor.f.params[0].id.type_annotation.type_name', readExprIdentName(tnUnion), 'T');
							}
						}
					}
				}
				ctorChecked = true;
			}
		}
		if (!fieldChecked)  { failed++; console.error('  FAIL 002: field `value` not found in body walk'); }
		if (!methodChecked) { failed++; console.error('  FAIL 002: method `get` not found in body walk'); }
		if (!ctorChecked)   { failed++; console.error('  FAIL 002: constructor not found in body walk'); }
	}
});

// =====================================================================
// Fixture 2 — 013_class_implements.js: c.implements arrays
// =====================================================================
safely('013_implements', () => {
	const ctx = verify(FIXTURE_IMPL, '013_implements');
	if (ctx) {
		const { u32, dyn, unionAt, str, safeArray, readExprIdentName, classOff, ast, programOff } = ctx;

		// Walk every ClassDeclaration in Program.body; check each c.implements
		// against the JSON-side counterpart.
		const progBody = dyn(programOff + PROGRAM_BODY_OFF);
		const jsonClasses = ast.body.filter((s) => s.type === 'ClassDeclaration');
		let kIdx = 0;
		for (let i = 0; i < progBody.len; i++) {
			const slotPtr = u32(progBody.data + i * 8);
			if (slotPtr === 0) continue;
			const u = unionAt(slotPtr);
			if (u.tag !== STMT_TAG_CLASSDECL) continue;
			const cOff = u.ptr;
			const jClass = jsonClasses[kIdx++];
			const expectedImpls = (jClass.implements || []).map((h) => h.expression && h.expression.name);

			const implsHeader = safeArray(`013 class[${kIdx-1}].implements`, cOff + CE_IMPLEMENTS_OFF, TSIH_SIZE);
			check(`013 class[${kIdx-1}].implements.len`, implsHeader.len, expectedImpls.length);
			for (let h = 0; h < implsHeader.len; h++) {
				const tihOff = implsHeader.data + h * TSIH_SIZE;
				const exprUnionPtr = u32(tihOff + TSIH_EXPRESSION_OFF);
				check(`013 class[${kIdx-1}].implements[${h}].expression.name`,
					readExprIdentName(exprUnionPtr),
					expectedImpls[h]);
			}
		}
		if (kIdx === 0) { failed++; console.error('  FAIL 013: no ClassDeclarations walked'); }
	}
});

if (failed > 0) {
	console.error(`\n${failed} failure(s)`);
	process.exit(1);
}
console.log('\n✅ class TS slot binary buffer matches JSON expectations');
