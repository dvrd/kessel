#!/usr/bin/env node
// TS-statement / JSX binary-buffer gate (S26 W3).
//
// Walks the raw-transfer binary AST emitted by `kessel raw` for the four
// curated W3 fixtures and asserts that the new TS-statement and JSX
// rewrites land where the JSON path says they should:
//
//   tests/fixtures/spec/typescript/011_interface_extends.js
//     * id.name on each TSInterfaceDeclaration         (BindingIdentifier)
//     * extends.length matches JSON                    ([dynamic]TSInterfaceHeritage)
//     * extends[0].expression resolves to an Identifier whose name == JSON
//
//   tests/fixtures/spec/typescript/012_const_enum.js
//     * id.name on each TSEnumDeclaration
//     * body.members.length matches JSON
//     * members[0].id resolves to an Identifier whose name == JSON
//
//   tests/fixtures/spec/typescript/015_namespace_module.js
//     * id resolves to an Identifier name (`Geo`, `Outer`) or a
//       StringLiteral value (`"ext-pkg"`) matching JSON
//     * body is a Maybe(^TSModuleBody) that resolves to an in-buffer offset
//
//   tests/fixtures/spec/jsx/005_nested_element.js
//     * declaration `b = <Outer><Middle><Inner /></Middle></Outer>` walks
//       the JSXElement tree end-to-end:
//         - opening_element.name = "Outer"
//         - children[0] is a JSXElement whose opening name = "Middle"
//         - that element's children[0] is a JSXElement whose opening name
//           = "Inner" and is self-closing (no closing_element set)
//     * declaration `a = <Foo bar={<Baz x={1} />} />` checks the spread
//       through opening_element.attributes[0].value (JSXExpressionContainer
//       wrapping a JSXElement <Baz>) — exercises the JSXAttribute /
//       JSXAttributeItem-with-value-variant path.
//
// Before S26 W3 the binary buffer left every TS-statement variant
// (TSInterfaceDeclaration / TSTypeAliasDeclaration / TSEnumDeclaration /
// TSModuleDeclaration) and every JSX-bearing Expression variant
// (JSXElement / JSXFragment / JSXText / JSXExpressionContainer /
// JSXEmptyExpression / JSXSpreadChild) silently un-rewritten in
// rewrite_statement / rewrite_expression. ChainExpression had the same
// gap. Red before W3 (e.g. /tmp/_probe_ns.ts had TSModuleDeclaration.id
// pointing at arena offset 22M+ in a 37K buffer); green after.
//
// Hard-coded byte offsets come from the same Odin layout-probe pattern
// used by verify_class_typescript.js. If any of the structs below shift,
// rerun the probe and update the constants.

'use strict';

const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

const ROOT = path.resolve(__dirname, '../..');
const KESSEL = path.join(ROOT, 'bin/kessel');

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
// Re-capture via /tmp/layout_probe_w3.odin if any struct shifts.
const HEADER                    = 20;
const PROGRAM_BODY_OFF          = 24;

// Statement-union tags (1-based, declaration order in src/ast.odin).
const STMT_TAG_TSINTERFACEDECL  = 26;
const STMT_TAG_TSENUMDECL       = 28;
const STMT_TAG_TSMODULEDECL     = 29;
const STMT_TAG_VARDECL          = 20;

// Expression-union tags.
const EXPR_TAG_STRINGLITERAL    = 4;
const EXPR_TAG_IDENTIFIER       = 9;
const EXPR_TAG_JSXELEMENT       = 34;
const EXPR_TAG_JSXEXPRCONTAINER = 37;

// TSInterfaceDeclaration layout (size 160).
const TSI_ID_OFF                = 16;        // BindingIdentifier (value)
const TSI_ID_NAME_OFF           = TSI_ID_OFF + 16;
const TSI_EXTENDS_OFF           = 56;        // [dynamic]TSInterfaceHeritage
const TSI_BODY_OFF              = 96;        // TSInterfaceBody (value)
const TSI_BODY_BODY_OFF         = TSI_BODY_OFF + 16; // dyn header inside TSInterfaceBody
// TSInterfaceHeritage value layout (size 32).
const TSIH_SIZE                 = 32;
const TSIH_EXPRESSION_OFF       = 16;        // ^Expression

// TSEnumDeclaration layout (size 112).
const TSE_ID_OFF                = 16;
const TSE_ID_NAME_OFF           = TSE_ID_OFF + 16;
const TSE_BODY_OFF              = 48;        // TSEnumBody (value)
const TSE_BODY_MEMBERS_OFF      = TSE_BODY_OFF + 16; // dyn header
// TSEnumMember value layout (size 32).
const TSEM_SIZE                 = 32;
const TSEM_ID_OFF               = 16;        // ^Expression (Identifier or StringLiteral)

// TSModuleDeclaration layout (size 48).
const TSM_ID_OFF                = 16;        // ^Expression (Identifier or StringLiteral)
const TSM_BODY_OFF              = 24;        // Maybe(^TSModuleBody) — 8 bytes (collapsed nullable ptr)

// VariableDeclaration: scan body to find init expression.
// VariableDeclaration layout: loc(16) + kind enum(?) + declarations(dyn).
// For our purposes we only need to find the dyn header; kessel emits the
// declarations dyn at offset 24 and each VariableDeclarator (size 56) has
// init Maybe(^Expression) at offset 32.
const VD_DECLS_OFF              = 24;
const VDR_SIZE                  = 56;
const VDR_INIT_OFF              = 32;

// Identifier layout: loc(16) + name string(16) + type_annotation Maybe(8).
const IDENT_NAME_OFF            = 16;

// StringLiteral layout: loc(16) + value string(16) + raw string(16).
const STRLIT_VALUE_OFF          = 16;

// JSXElement layout (size 72).
const JSXE_OPENING_OFF          = 16;        // ^JSXOpeningElement
const JSXE_CHILDREN_OFF         = 24;        // [dynamic]JSXChild (16-byte slots)
const JSXE_CLOSING_OFF          = 64;        // Maybe(^JSXClosingElement) — 8 bytes

// JSXOpeningElement layout (size 104).
const JSXOE_NAME_OFF            = 16;        // JSXElementName union (16 bytes: value | ptr+tag)
const JSXOE_ATTRS_OFF           = 56;        // [dynamic]JSXAttributeItem (72-byte slots)

// JSXIdentifier layout (size 32) — name string at +16. The
// JSXElementName union stores a JSXIdentifier value inline at offset 0
// when its variant is JSXIdentifier (tag 1), so the name string lives
// at union+16 for the inline-value case.
const JSXID_NAME_OFF            = 16;

// Union tag offsets. For all-pointer-variant unions (Statement,
// Expression, JSXChild) the tag follows the 8-byte ptr, so it lives
// at +8 inside the 16-byte union slot. For mixed-value-variant unions
// the tag follows the largest value variant:
//   * JSXElementName / JSXAttributeName / JSXMemberObject — the inline
//     JSXIdentifier value variant is 32 bytes, total slot 40 bytes,
//     tag at +32.
//   * JSXAttributeItem — the inline JSXAttribute value variant is 64
//     bytes, total slot 72 bytes, tag at +64.
const NAMEUNION_TAG_OFF         = 32;
const ATTRITEM_TAG_OFF          = 64;

// JSXAttribute layout (size 64); embedded inline at offset 0 of each
// 72-byte JSXAttributeItem array slot (the union tag follows at offset
// 64). JSXAttribute.value is a Maybe(^Expression) at +56 (8 bytes).
const JSXATTRITEM_SIZE          = 72;
const JSXATTR_NAME_OFF          = 16;        // JSXAttributeName union — JSXIdentifier inline @+16+16
const JSXATTR_VALUE_OFF         = 56;        // Maybe(^Expression)

// JSXChild slot layout — 16-byte union with inner ptr@0, tag@8.
const JSXCHILD_SIZE             = 16;
const JSXCHILD_TAG_ELEMENT      = 1;         // ^JSXElement (1-based)

// JSXElementName tags — 1-based per declaration order in src/ast.odin
// `JSXElementName :: union { JSXIdentifier, ^JSXMemberExpression, ^JSXNamespacedName }`.
const JSXNAME_TAG_IDENTIFIER    = 1;

// JSXAttributeItem tags — 1-based:
// `JSXAttributeItem :: union { JSXAttribute, ^JSXSpreadAttribute }`.
const JSXATTRITEM_TAG_ATTRIBUTE = 1;

// JSXExpressionContainer layout (size 24): expression ^Expression @+16.
const JSXEC_EXPRESSION_OFF      = 16;

// ----- Per-fixture verification helpers ---------------------------------
function loadFixture(fixtureAbs, lang) {
	const jsonText = execSync(`${KESSEL} parse ${fixtureAbs} --lang=${lang}`, { encoding: 'utf8' });
	const ast = JSON.parse(jsonText);
	const outBin = `/tmp/_verify_w3_${path.basename(fixtureAbs, '.js')}.bin`;
	execSync(`${KESSEL} raw ${fixtureAbs} --lang=${lang} --out ${outBin}`, { stdio: 'pipe' });
	const bin = fs.readFileSync(outBin);
	if (bin.readUInt32LE(0) !== 0x4B455353) { console.error('bad magic'); process.exit(1); }
	const programOff = bin.readUInt32LE(8);
	const buf = bin.subarray(HEADER);
	const view = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
	const source = fs.readFileSync(fixtureAbs);

	const STRING_ARENA_FLAG = 0x80000000;
	function inBounds(off, n) { return off >= 0 && off + n <= buf.length; }
	function u32(off) {
		if (!inBounds(off, 4)) throw new RangeError(`u32 read at ${off} out of buffer (size ${buf.length})`);
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
			console.error(`  FAIL ${lab}: dyn header looks unrewritten {data=${h.data}, len=${h.len}, bufSize=${buf.length}}`);
			return { data: 0, len: 0 };
		}
		return h;
	}
	// Maybe(^T) collapsed-nullable-pointer: set iff the u32 is non-zero AND
	// inside the buffer. Catches the unrewritten-ptr case where bytes look
	// like a giant out-of-range arena address.
	function maybePtrSet(lab, fieldAddr, expectedSet) {
		const v = u32(fieldAddr);
		const inside = v > 0 && v < buf.length;
		if (expectedSet && !inside) {
			failed++;
			console.error(`  FAIL ${lab}: Maybe ptr ${v} (buf=${buf.length}) — looks unrewritten`);
			return 0;
		}
		if (!expectedSet && v !== 0 && inside === false) {
			failed++;
			console.error(`  FAIL ${lab}: expected nil, got out-of-buf ${v}`);
			return 0;
		}
		return inside ? v : 0;
	}
	// Read an Identifier name from an Expression union ptr.
	function readExprIdentName(exprUnionPtr) {
		if (exprUnionPtr === 0) return '<nil>';
		const u = unionAt(exprUnionPtr);
		if (u.tag !== EXPR_TAG_IDENTIFIER) return `<expr tag ${u.tag}>`;
		return str(u.ptr + IDENT_NAME_OFF);
	}
	// Read a StringLiteral value from an Expression union ptr.
	function readExprStringValue(exprUnionPtr) {
		if (exprUnionPtr === 0) return '<nil>';
		const u = unionAt(exprUnionPtr);
		if (u.tag !== EXPR_TAG_STRINGLITERAL) return `<expr tag ${u.tag}>`;
		return str(u.ptr + STRLIT_VALUE_OFF);
	}
	// Walk Program.body and yield {offset, tag, jsonNode}.
	function* iterTopLevel() {
		const progBody = dyn(programOff + PROGRAM_BODY_OFF);
		for (let i = 0; i < progBody.len; i++) {
			const slotPtr = u32(progBody.data + i * 8);
			if (slotPtr === 0) continue;
			const u = unionAt(slotPtr);
			yield { ptr: u.ptr, tag: u.tag, json: ast.body[i], idx: i };
		}
	}
	return {
		buf, view, u32, u8, dyn, unionAt, str,
		safeArray, maybePtrSet, readExprIdentName, readExprStringValue,
		iterTopLevel, ast, programOff,
	};
}

// Wrap each fixture body in a try so a stray RangeError on an unrewritten
// pointer shows up as a clean labelled FAIL, not a Node stack-trace crash.
function safely(label, fn) {
	try { fn(); } catch (e) {
		failed++;
		console.error(`  FAIL ${label}: ${e.message}`);
	}
}

// =====================================================================
// Fixture 1 — 011_interface_extends.js (TSInterfaceDeclaration)
// =====================================================================
safely('011_interfaces', () => {
	const fix = path.join(ROOT, 'tests/fixtures/spec/typescript/011_interface_extends.js');
	const ctx = loadFixture(fix, 'ts');
	const { u32, str, safeArray, readExprIdentName, iterTopLevel } = ctx;

	let walked = 0;
	for (const stmt of iterTopLevel()) {
		if (stmt.tag !== STMT_TAG_TSINTERFACEDECL) continue;
		walked++;
		const cOff = stmt.ptr;
		const json = stmt.json;

		check(`011 interface[${walked-1}].id.name`,
			str(cOff + TSI_ID_NAME_OFF),
			json.id.name);

		const ext = safeArray(`011 interface[${walked-1}].extends`, cOff + TSI_EXTENDS_OFF, TSIH_SIZE);
		check(`011 interface[${walked-1}].extends.length`, ext.len, (json.extends || []).length);

		// For the first heritage when present, compare the binary side's
		// expression against the JSON-side shape. The Identifier-named
		// `Base` case is the common one; the qualified-parent case
		// (`extends ns.Base`) parses as a MemberExpression in JSON — we
		// only assert the binary union resolves to a non-zero, in-buffer
		// expression there (the binary-vs-JSON shape parity is covered by
		// the deep-families gate).
		if (ext.len > 0) {
			const tihOff = ext.data;
			const exprUnionPtr = u32(tihOff + TSIH_EXPRESSION_OFF);
			const jsonExpr = json.extends[0].expression;
			if (jsonExpr && jsonExpr.type === 'Identifier') {
				check(`011 interface[${walked-1}].extends[0].expression.name`,
					readExprIdentName(exprUnionPtr),
					jsonExpr.name);
			} else {
				// MemberExpression / qualified-parent shape — just assert the
				// expression union ptr resolves into the buffer.
				if (exprUnionPtr === 0 || exprUnionPtr >= ctx.buf.length) {
					failed++;
					console.error(`  FAIL 011 interface[${walked-1}].extends[0].expression: union ptr ${exprUnionPtr} out of buffer`);
				} else {
					console.log(`  OK   011 interface[${walked-1}].extends[0].expression: in-buffer (jsonType=${jsonExpr && jsonExpr.type})`);
				}
			}
		}
	}
	if (walked === 0) {
		failed++;
		console.error('  FAIL 011: no TSInterfaceDeclaration walked');
	}
});

// =====================================================================
// Fixture 2 — 012_const_enum.js (TSEnumDeclaration)
// =====================================================================
safely('012_enums', () => {
	const fix = path.join(ROOT, 'tests/fixtures/spec/typescript/012_const_enum.js');
	const ctx = loadFixture(fix, 'ts');
	const { u32, str, safeArray, readExprIdentName, iterTopLevel } = ctx;

	let walked = 0;
	for (const stmt of iterTopLevel()) {
		if (stmt.tag !== STMT_TAG_TSENUMDECL) continue;
		walked++;
		const eOff = stmt.ptr;
		const json = stmt.json;

		check(`012 enum[${walked-1}].id.name`,
			str(eOff + TSE_ID_NAME_OFF),
			json.id.name);

		const members = safeArray(`012 enum[${walked-1}].body.members`, eOff + TSE_BODY_MEMBERS_OFF, TSEM_SIZE);
		check(`012 enum[${walked-1}].body.members.length`, members.len, (json.body.members || json.members || []).length);

		if (members.len > 0) {
			const m0Off = members.data;
			const idUnionPtr = u32(m0Off + TSEM_ID_OFF);
			const jsonMembers = json.body.members || json.members;
			check(`012 enum[${walked-1}].members[0].id.name`,
				readExprIdentName(idUnionPtr),
				jsonMembers[0].id.name);
		}
	}
	if (walked === 0) {
		failed++;
		console.error('  FAIL 012: no TSEnumDeclaration walked');
	}
});

// =====================================================================
// Fixture 3 — 015_namespace_module.js (TSModuleDeclaration)
// =====================================================================
safely('015_modules', () => {
	const fix = path.join(ROOT, 'tests/fixtures/spec/typescript/015_namespace_module.js');
	const ctx = loadFixture(fix, 'ts');
	const { u32, unionAt, str, maybePtrSet, readExprIdentName, readExprStringValue, iterTopLevel } = ctx;

	let walked = 0;
	for (const stmt of iterTopLevel()) {
		if (stmt.tag !== STMT_TAG_TSMODULEDECL) continue;
		walked++;
		const mOff = stmt.ptr;
		const json = stmt.json;

		// Body Maybe(^TSModuleBody) — every fixture entry has a body.
		maybePtrSet(`015 module[${walked-1}].body`, mOff + TSM_BODY_OFF, true);

		// id is a ^Expression union; resolve to either an Identifier name
		// or a StringLiteral value depending on the JSON-side type. As of
		// S26 W4b the JSON path folds `namespace A.B { ... }` into a
		// TSQualifiedName id (left-deep chain). The binary path does NOT
		// fold — the fold is purely a JSON-emit transform — so the binary's
		// id is still the LEFTMOST Identifier of the chain. Read JSON's
		// leftmost ident off the TSQualifiedName by walking `.left` until
		// we hit an Identifier; compare that to the binary id.
		const idUnionPtr = u32(mOff + TSM_ID_OFF);
		const u = unionAt(idUnionPtr);
		if (json.id.type === 'Identifier') {
			check(`015 module[${walked-1}].id.name`,
				readExprIdentName(idUnionPtr),
				json.id.name);
		} else if (json.id.type === 'Literal' || json.id.type === 'StringLiteral') {
			check(`015 module[${walked-1}].id.value`,
				readExprStringValue(idUnionPtr),
				json.id.value);
		} else if (json.id.type === 'TSQualifiedName') {
			let leftmost = json.id;
			while (leftmost && leftmost.type === 'TSQualifiedName') leftmost = leftmost.left;
			if (leftmost && leftmost.type === 'Identifier') {
				check(`015 module[${walked-1}].id.leftmost.name (binary unfolded)`,
					readExprIdentName(idUnionPtr),
					leftmost.name);
			} else {
				failed++;
				console.error(`  FAIL 015 module[${walked-1}].id: TSQualifiedName has non-Identifier leftmost ${leftmost && leftmost.type}`);
			}
		} else {
			failed++;
			console.error(`  FAIL 015 module[${walked-1}].id: unhandled JSON id.type=${json.id.type}, binary union tag=${u.tag}`);
		}
	}
	if (walked === 0) {
		failed++;
		console.error('  FAIL 015: no TSModuleDeclaration walked');
	}
});

// =====================================================================
// Fixture 4 — 005_nested_element.js (JSXElement, JSXAttribute, ExprContainer)
// =====================================================================
safely('005_jsx_nested', () => {
	const fix = path.join(ROOT, 'tests/fixtures/spec/jsx/005_nested_element.js');
	const ctx = loadFixture(fix, 'jsx');
	const { u32, u8, unionAt, str, safeArray, maybePtrSet, iterTopLevel } = ctx;

	// Helper: from a binary VariableDeclaration ptr, resolve declarations[0].init
	// to the inner Expression union ptr; assert init is a JSXElement.
	function jsxInitOf(stmtPtr) {
		const decls = safeArray('005 var.declarations', stmtPtr + VD_DECLS_OFF, VDR_SIZE);
		if (decls.len < 1) return null;
		const initPtr = u32(decls.data + VDR_INIT_OFF);
		if (initPtr === 0 || initPtr >= ctx.buf.length) {
			failed++;
			console.error('  FAIL 005 var.init looks unrewritten');
			return null;
		}
		const initUnion = unionAt(initPtr);
		if (initUnion.tag !== EXPR_TAG_JSXELEMENT) {
			failed++;
			console.error(`  FAIL 005 var.init.tag = ${initUnion.tag}, expected JSXElement (${EXPR_TAG_JSXELEMENT})`);
			return null;
		}
		return initUnion.ptr;
	}

	// Walk a JSXElement — return its opening name (assumes JSXIdentifier
	// variant; other shapes return a tagged sentinel for FAIL output).
	function jsxOpeningName(elemPtr, lab) {
		const openingPtr = u32(elemPtr + JSXE_OPENING_OFF);
		if (openingPtr === 0 || openingPtr >= ctx.buf.length) {
			failed++;
			console.error(`  FAIL ${lab}: opening_element ptr unrewritten (${openingPtr})`);
			return '<bad-opening>';
		}
		// JSXOpeningElement.name is a JSXElementName union @+16 (40 bytes
		// wide — inline JSXIdentifier value variant is 32 bytes, tag at
		// +32). When the variant is JSXIdentifier (tag 1) the name string
		// lives at union+16.
		const nameTag = u8(openingPtr + JSXOE_NAME_OFF + NAMEUNION_TAG_OFF);
		if (nameTag !== JSXNAME_TAG_IDENTIFIER) {
			return `<jsxname tag ${nameTag}>`;
		}
		return str(openingPtr + JSXOE_NAME_OFF + JSXID_NAME_OFF);
	}

	const stmts = [...iterTopLevel()].filter(s => s.tag === STMT_TAG_VARDECL);
	check('005 var-decl count', stmts.length, 2);
	if (stmts.length < 2) return;

	// declaration `a = <Foo bar={<Baz x={1} />} />`
	const aElem = jsxInitOf(stmts[0].ptr);
	if (aElem !== null) {
		check('005 a.openingName', jsxOpeningName(aElem, '005 a'), 'Foo');

		// a's children: [] (self-closing). closing_element should be unset.
		const aChildren = safeArray('005 a.children', aElem + JSXE_CHILDREN_OFF, JSXCHILD_SIZE);
		check('005 a.children.length', aChildren.len, 0);
		maybePtrSet('005 a.closing_element', aElem + JSXE_CLOSING_OFF, false);

		// Walk attributes — first attribute is `bar={<Baz x={1} />}`.
		// JSXOpeningElement.attributes lives on the opening element struct,
		// NOT on JSXElement. Resolve via the JSXElement.opening_element ptr.
		const openingPtr = u32(aElem + JSXE_OPENING_OFF);
		const attrs = safeArray('005 a.opening.attributes', openingPtr + JSXOE_ATTRS_OFF, JSXATTRITEM_SIZE);
		check('005 a.attributes.length', attrs.len, 1);
		if (attrs.len > 0) {
			const attrSlot = attrs.data;
			const attrTag = u8(attrSlot + ATTRITEM_TAG_OFF);
			check('005 a.attr[0] tag (1=JSXAttribute)', attrTag, JSXATTRITEM_TAG_ATTRIBUTE);
			// Attribute name (JSXIdentifier inline at +16): "bar"
			const attrNameTag = u8(attrSlot + JSXATTR_NAME_OFF + NAMEUNION_TAG_OFF);
			if (attrNameTag === JSXNAME_TAG_IDENTIFIER) {
				check('005 a.attr[0].name', str(attrSlot + JSXATTR_NAME_OFF + JSXID_NAME_OFF), 'bar');
			}
			// Attribute value: Maybe(^Expression) → JSXExpressionContainer
			const valuePtr = maybePtrSet('005 a.attr[0].value', attrSlot + JSXATTR_VALUE_OFF, true);
			if (valuePtr !== 0) {
				const valueUnion = unionAt(valuePtr);
				check('005 a.attr[0].value tag (37=JSXExpressionContainer)', valueUnion.tag, EXPR_TAG_JSXEXPRCONTAINER);
				if (valueUnion.tag === EXPR_TAG_JSXEXPRCONTAINER) {
					// expression inside the container is itself a JSXElement <Baz />
					const inner = u32(valueUnion.ptr + JSXEC_EXPRESSION_OFF);
					const innerUnion = unionAt(inner);
					check('005 a.attr[0].value.expression tag (34=JSXElement)', innerUnion.tag, EXPR_TAG_JSXELEMENT);
					if (innerUnion.tag === EXPR_TAG_JSXELEMENT) {
						check('005 a.attr[0].value.expression.openingName',
							jsxOpeningName(innerUnion.ptr, '005 a.attr[0].value'),
							'Baz');
					}
				}
			}
		}
	}

	// declaration `b = <Outer><Middle><Inner /></Middle></Outer>`
	const bElem = jsxInitOf(stmts[1].ptr);
	if (bElem !== null) {
		check('005 b.openingName', jsxOpeningName(bElem, '005 b'), 'Outer');
		maybePtrSet('005 b.closing_element', bElem + JSXE_CLOSING_OFF, true);

		const bChildren = safeArray('005 b.children', bElem + JSXE_CHILDREN_OFF, JSXCHILD_SIZE);
		check('005 b.children.length', bChildren.len, 1);
		if (bChildren.len === 1) {
			const childTag = u8(bChildren.data + 8);
			check('005 b.children[0].tag (1=^JSXElement)', childTag, JSXCHILD_TAG_ELEMENT);
			const middlePtr = u32(bChildren.data);
			check('005 b.children[0].openingName', jsxOpeningName(middlePtr, '005 b.middle'), 'Middle');

			const mChildren = safeArray('005 b.middle.children', middlePtr + JSXE_CHILDREN_OFF, JSXCHILD_SIZE);
			check('005 b.middle.children.length', mChildren.len, 1);
			if (mChildren.len === 1) {
				const innerPtr = u32(mChildren.data);
				check('005 b.middle.children[0].openingName',
					jsxOpeningName(innerPtr, '005 b.inner'),
					'Inner');
				// <Inner /> is self-closing — closing_element must be unset.
				maybePtrSet('005 b.inner.closing_element', innerPtr + JSXE_CLOSING_OFF, false);
			}
		}
	}
});

if (failed > 0) {
	console.error(`\n${failed} failure(s)`);
	process.exit(1);
}
console.log('\n✅ TS-statement / JSX binary-buffer matches JSON expectations');
