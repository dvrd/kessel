#!/usr/bin/env node
// Integration verification: parse with OXC (source of truth) and Kessel raw,
// walk both ASTs and compare structure + values.
//
// Usage: node verify_integration.js <file.js> [--verbose] [--baseline] [--update]
//
// Default mode is zero-tolerance: any field mismatch fails the gate.
//
// `--baseline` switches to a baseline-gated comparison: the per-file
// mismatch count is compared to `tests/baselines/integration_baseline.json`;
// an increase fails, a decrease is reported as an improvement, exact match
// passes. Matches the pattern used by verify_spec_compliance.js so the two
// gates behave consistently when they share the same real-world corpus.
//
// `--update` re-captures the baseline from the current run. Use after an
// intentional fix or after a deliberate parser change that shifts mismatch
// counts. Without `--baseline` or `--update`, the gate is strict.

const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');
const { parseSync } = require(path.resolve(__dirname, '../../bench/node_modules/oxc-parser'));

const ROOT = path.resolve(__dirname, '../..');
const BASELINE_PATH = path.join(ROOT, 'tests/baselines/integration_baseline.json');

const argv = process.argv.slice(2);
const file = argv.find((a) => !a.startsWith('--'));
const verbose = argv.includes('--verbose');
const BASELINE_MODE = argv.includes('--baseline');
const UPDATE = argv.includes('--update');
if (!file) {
  console.error('Usage: node verify_integration.js <file.js> [--verbose] [--baseline] [--update]');
  process.exit(1);
}

// Baseline paths are stored relative to the repo root so they're stable
// across `cd` contexts and across developers. Resolve the CLI `file` arg
// relative to the current working dir, then render the relative form for
// the baseline key.
const absFile = path.isAbsolute(file) ? file : path.resolve(process.cwd(), file);
const baselineKey = path.relative(ROOT, absFile);

// W5: detect dialect from path so the gate can walk TS/TSX/JSX fixtures end
// to end. `tests/fixtures/spec/typescript/*.js` parses as TS, `spec/tsx/*.js`
// as TSX, `spec/jsx/*.js` as JSX; everything else is plain JS. Mirrors
// verify_json_deep.js's detectDialect/syntheticName helpers, which is the
// single source of truth used by the deep-emit gate — kessel and OXC
// must agree on the grammar in play.
function detectDialect(p) {
  if (p.includes('/spec/jsx/'))        return 'jsx';
  if (p.includes('/spec/tsx/'))        return 'tsx';
  if (p.includes('/spec/typescript/')) return 'ts';
  if (p.includes('/spec/ambiguity/'))  return 'tsx';
  // spec/interactions/ is a mixed bucket where dialect is encoded in
  // the filename marker (`_jsx_`, `_ts_`). Mirrors verify_json_deep.js.
  if (p.includes('/spec/interactions/')) {
    if (/_jsx_/.test(p)) return 'jsx';
    if (/_ts_/.test(p))  return 'ts';
  }
  return 'js';
}
// OXC infers JS/JSX/TS/TSX from filename extension, but our fixtures all
// end in `.js` regardless of content; synthesize an extension so OXC's
// JSX/TS grammar fires. Kessel reads `--lang=` for the same decision.
function syntheticName(p, dialect) {
  const base = path.basename(p);
  switch (dialect) {
    case 'jsx': return base.replace(/\.js$/, '.jsx');
    case 'ts':  return base.replace(/\.js$/, '.ts');
    case 'tsx': return base.replace(/\.js$/, '.tsx');
    default:    return base;
  }
}
const dialect = detectDialect(absFile);
const langFlag = dialect === 'js' ? '' : ` --lang=${dialect}`;

const kesselBin = path.resolve(__dirname, '../../bin/kessel');
const source = fs.readFileSync(file, 'utf8');
const name = syntheticName(absFile, dialect);

// ============================================================
// OXC: parse (source of truth)
// ============================================================
const oxc = parseSync(name, source, { preserveParens: false });
const oxcAst = oxc.program;

// ============================================================
// Kessel: raw transfer
// ============================================================
execSync(`${kesselBin} raw "${file}"${langFlag} --out /tmp/_verify_integ.bin`, { stdio: 'pipe' });
const bin = fs.readFileSync('/tmp/_verify_integ.bin');
const HEADER = 20;
if (bin.readUInt32LE(0) !== 0x4B455353) { console.error('Bad magic'); process.exit(1); }
const progOff = bin.readUInt32LE(8);
const buf = bin.subarray(HEADER);
const view = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);

function u32(off) { return view.getUint32(off, true); }
function u8(off)  { return view.getUint8(off); }
function f64(off) { return view.getFloat64(off, true); }
// Strings are byte offsets into source OR into the arena buffer. The high bit
// (STRING_ARENA_FLAG = 0x8000_0000) discriminates:
//   bit 31 = 0 → offset relative to source text
//   bit 31 = 1 → offset relative to `buf` (arena, post-header) — cooked strings
//                from Bug E / other arena-allocated places
// See src/raw_transfer.odin for the encoding definition.
const STRING_ARENA_FLAG = 0x80000000;
const sourceBuf = Buffer.from(source, 'utf8');
function str(off) {
  const raw = u32(off), l = u32(off + 4);
  if (l === 0 || l >= 1e6) return '';
  if (raw & STRING_ARENA_FLAG) {
    const arenaOff = raw & 0x7fffffff;
    return buf.toString('utf8', arenaOff, arenaOff + l);
  }
  return sourceBuf.toString('utf8', raw, raw + l);
}
function dyn(off) { return { data: u32(off), len: u32(off + 4) }; }
function union(off) { return { ptr: u32(off), tag: u8(off + 8) }; }

// Tag → type name mappings. MUST track src/ast.odin's `Expression ::
// union { ... }` declaration in declaration order, because Odin tags
// union variants 1..N in source order. When a new variant is added to
// the union (e.g. ^ChainExpression between Super and ArrayExpression),
// every subsequent tag shifts by one — this table needs to move with
// it or the raw-transfer verifier reads every downstream node as the
// wrong type.
const EXPR = { 1:'NullLiteral',2:'BooleanLiteral',3:'NumericLiteral',4:'StringLiteral',
  5:'BigIntLiteral',6:'RegExpLiteral',7:'TemplateLiteral',8:'TaggedTemplateExpression',
  9:'Identifier',10:'PrivateIdentifier',11:'ThisExpression',12:'Super',
  13:'ChainExpression',
  14:'ArrayExpression',15:'ObjectExpression',16:'FunctionExpression',
  17:'ArrowFunctionExpression',18:'ClassExpression',19:'MemberExpression',
  20:'CallExpression',21:'NewExpression',22:'ConditionalExpression',
  23:'UpdateExpression',24:'UnaryExpression',25:'BinaryExpression',
  26:'LogicalExpression',27:'AssignmentExpression',28:'SequenceExpression',
  29:'SpreadElement',30:'YieldExpression',31:'AwaitExpression',
  32:'ImportExpression',33:'MetaProperty',
  // JSX + TS variants come next but aren't currently walked by the
  // integration verifier; list them so tag lookups don't return
  // `undefined` and mislead the caller.
  34:'JSXElement',35:'JSXFragment',36:'JSXText',
  37:'JSXExpressionContainer',38:'JSXEmptyExpression',39:'JSXSpreadChild',
  40:'TSAsExpression',41:'TSSatisfiesExpression',42:'TSNonNullExpression',
  43:'TSTypeAssertion',44:'ParenthesizedExpression' };

const STMT = { 1:'ExpressionStatement',2:'EmptyStatement',3:'BlockStatement',
  4:'DebuggerStatement',5:'ReturnStatement',6:'BreakStatement',
  7:'ContinueStatement',8:'LabeledStatement',9:'IfStatement',
  10:'SwitchStatement',11:'WhileStatement',12:'DoWhileStatement',
  13:'ForStatement',14:'ForInStatement',15:'ForOfStatement',
  16:'WithStatement',17:'ThrowStatement',18:'TryStatement',
  19:'FunctionDeclaration',20:'VariableDeclaration',21:'ClassDeclaration',
  22:'ImportDeclaration',23:'ExportNamedDeclaration',24:'ExportDefaultDeclaration',
  25:'ExportAllDeclaration',
  // W5: TS-statement variants. Without these tags 26-29 surface as
  // STMT[tag] = undefined and the walker's `if (!kType) return;` guard
  // silently skips the node — making the integration gate completely
  // blind to the binary fixes shipped in S26 W3 on TS-stmt slots.
  26:'TSInterfaceDeclaration',27:'TSTypeAliasDeclaration',
  28:'TSEnumDeclaration',29:'TSModuleDeclaration' };

// Enum string tables (mirror src/parser.odin enum definitions).
const BIN_OP = ['+','-','*','/','%','**','|','^','&','<<','>>','>>>','==','!=','===','!==','<','<=','>','>=','instanceof','in'];
const LOG_OP = ['||','&&','??'];
const ASN_OP = ['=','+=','-=','*=','/=','%=','**=','<<=','>>=','>>>=','|=','^=','&=','&&=','||=','??='];
const UN_OP  = ['-','+','!','~','typeof','void','delete'];
const UPD_OP = ['++','--'];
const PROP_KIND = ['init','get','set','method'];

// Kessel → OXC type mapping (ESTree differences). After T1 (ESTree Literal)
// Kessel already emits "Literal" for the six primitive literal types, so
// this mapping is a no-op today — kept for any future Kessel-OXC drift.
function normalizeType(kesselType) {
  if (['NumericLiteral','StringLiteral','BooleanLiteral','NullLiteral','BigIntLiteral','RegExpLiteral'].includes(kesselType))
    return 'Literal';
  return kesselType;
}

// ============================================================
// W5: layout constants for the new node types the walker handles.
// Mirror src/ast.odin. Adopted from verify_class_decorators.js,
// verify_class_typescript.js, and verify_ts_statements_jsx.js — those
// gates already exercised the offsets, so reusing them here is a port,
// not a re-derivation. If any of these structs shift, rerun the
// /tmp/layout_probe*.odin pattern referenced by those gates and update.
// ============================================================

// ClassExpression (size 216) — ClassDeclaration shares layout via
// `using expr: ClassExpression`.
const CE_ID_NAME_OFF        = 32;   // Maybe(BindingIdentifier).name string
const CE_BODY_BODY_OFF      = 80;   // ClassBody.body dyn header
const CE_DECORATORS_OFF     = 120;  // [dynamic]Decorator dyn header

// ClassElement (size 112).
const CELEM_SIZE            = 112;
const CELEM_KEY_OFF         = 16;   // ^Expression union ptr
const CELEM_VALUE_OFF       = 24;   // Maybe(^Expression) — Method body
const CELEM_DECORATORS_OFF  = 48;   // [dynamic]Decorator dyn header

// Decorator (size 24).
const DECOR_SIZE            = 24;
const DECOR_EXPR_OFF        = 16;   // ^Expression union ptr

// TSInterfaceDeclaration (size 160).
const TSI_ID_NAME_OFF       = 32;
const TSI_EXTENDS_OFF       = 56;   // [dynamic]TSInterfaceHeritage
const TSIH_SIZE             = 32;
const TSIH_EXPRESSION_OFF   = 16;

// TSTypeAliasDeclaration: id is BindingIdentifier at +16, name at +32.
const TSA_ID_NAME_OFF       = 32;

// TSEnumDeclaration (size 112).
const TSE_ID_NAME_OFF       = 32;
const TSE_BODY_MEMBERS_OFF  = 64;   // TSEnumBody.members dyn header
const TSEM_SIZE             = 32;
const TSEM_ID_OFF           = 16;   // ^Expression (Identifier or StringLiteral)

// TSModuleDeclaration (size 48). Note: the JSON path folds qualified
// `namespace A.B { ... }` into a TSQualifiedName; the binary path does
// NOT fold (the fold is purely a JSON-emit transform). The integration
// walker therefore only validates that .id resolves to an in-buffer
// Expression and .body's Maybe ptr is set. Deep shape parity is covered
// by verify_json_deep / verify_ts_statements_jsx.
const TSM_ID_OFF            = 16;   // ^Expression union ptr
const TSM_BODY_OFF          = 24;   // Maybe(^TSModuleBody)

// JSXElement (size 72).
const JSXE_OPENING_OFF      = 16;   // ^JSXOpeningElement
const JSXE_CHILDREN_OFF     = 24;   // [dynamic]JSXChild (16-byte slots)
const JSXE_CLOSING_OFF      = 64;   // Maybe(^JSXClosingElement)

// JSXFragment: loc(16) + opening_fragment(value, JSXOpeningFragment is
// just Loc=16) + children(dyn=16) + closing_fragment(Loc=16).
const JSXFRAG_CHILDREN_OFF  = 32;

// JSXOpeningElement: loc(16) + name(JSXElementName 40-byte union) +
// attributes(dyn=16) + self_closing(1).
const JSXOE_NAME_OFF        = 16;
const JSXOE_ATTRS_OFF       = 56;

// JSXIdentifier value: loc(16) + name string(16). When the
// JSXElementName union variant is JSXIdentifier (tag 1) the name string
// lives at union+16. Tag for the 40-byte JSXElementName union is at +32
// (after the 32-byte inline JSXIdentifier value variant).
const JSXID_NAME_OFF        = 16;
const JSXNAME_TAG_OFF       = 32;
const JSXNAME_TAG_IDENT     = 1;

// JSXChild slot: 16-byte union (inner ptr@0, tag@8). Variant tags
// 1=^JSXElement, 2=^JSXFragment, 3=^JSXText, 4=^JSXExpressionContainer,
// 5=^JSXSpreadChild (1-based per src/ast.odin).
const JSXCHILD_SIZE         = 16;
const JSXCHILD_TAG_ELEMENT  = 1;
const JSXCHILD_TAG_FRAGMENT = 2;
const JSXCHILD_TAG_EXPRCONT = 4;

// JSXExpressionContainer (size 24): expression ^Expression @+16.
const JSXEC_EXPRESSION_OFF  = 16;

// ChainExpression (size 24): expression ^Expression @+16.
const CHAIN_EXPRESSION_OFF  = 16;

// ParenthesizedExpression (size 24): expression ^Expression @+16.
const PAREN_EXPRESSION_OFF  = 16;

// TSAsExpression / TSSatisfiesExpression / TSNonNullExpression: same
// shape — expression at +16. TSTypeAssertion is the odd one out
// (type_annotation@16, expression@24) because it's the only TS
// expression where the type appears textually first.
const TS_AS_EXPRESSION_OFF        = 16;
const TS_SATISFIES_EXPRESSION_OFF = 16;
const TS_NONNULL_EXPRESSION_OFF   = 16;
const TS_ASSERTION_EXPRESSION_OFF = 24;

// TaggedTemplateExpression (size 32): tag@16, quasi@24 (both ^Expression).
const TT_TAG_OFF            = 16;
const TT_QUASI_OFF          = 24;

// TemplateLiteral: loc(16) + quasis([dynamic]TemplateElement) +
// expressions([dynamic]^Expression). Each `[dynamic]T` field is 40
// bytes wide in the binary buffer (data + len + cap + allocator), not
// 8 — raw_transfer keeps the Odin struct stride to preserve alignment
// even though `dyn()` reads only the {data, len} prefix. So expressions
// lives at +16+40 = +56, not +32. Burned by this mistake while shipping
// W5: with TPL_EXPRS_OFF=32 the read lands in the cap field of quasis,
// which raw_transfer doesn't rewrite — hence kessel=0 vs oxc=N for
// every template literal containing interpolations on prettier.js.
const TPL_QUASIS_OFF        = 16;
const TPL_EXPRS_OFF         = 56;

// Identifier name string lives at +16 (Identifier struct: loc + name +
// type_annotation Maybe + optional bool).
const IDENT_NAME_OFF        = 16;

let errors = 0;
let matched = 0;

function fail(p, msg) { errors++; if (errors <= 30) console.error(`  FAIL ${p}: ${msg}`); }
function ok(p) { matched++; if (verbose) console.log(`  OK ${p}`); }

function eq(p, raw, oxc) {
  if (raw === oxc) { ok(p); return true; }
  fail(p, `kessel=${JSON.stringify(raw)} oxc=${JSON.stringify(oxc)}`);
  return false;
}

// ============================================================
// Walk OXC AST, read corresponding Kessel raw node, compare
// ============================================================

function verifyProgram() {
  const body = dyn(progOff + 24);
  eq('program.body.length', body.len, oxcAst.body.length);

  for (let i = 0; i < Math.min(body.len, oxcAst.body.length); i++) {
    const slotOff = body.data + i * 8;
    const stmtUOff = u32(slotOff);
    if (stmtUOff === 0) { fail(`body[${i}]`, 'null'); continue; }
    const su = union(stmtUOff);
    const kType = STMT[su.tag];
    const oNode = oxcAst.body[i];
    eq(`body[${i}].type`, normalizeType(kType), oNode.type);

    if (su.ptr > 0 && su.ptr < buf.length) {
      verifyStmt(su.ptr, kType, oNode, `body[${i}]`);
    }
  }
}

function verifyStmt(off, kType, oNode, p) {
  if (!kType || !oNode) return;
  // Check bounds before proceeding
  if (off < 0 || off >= buf.length) return;
  switch (kType) {
    case 'VariableDeclaration': {
      const kinds = ['var','let','const'];
      eq(`${p}.kind`, kinds[u32(off+16)], oNode.kind);
      const decls = dyn(off + 24);
      eq(`${p}.declarations.len`, decls.len, oNode.declarations.length);
      for (let i = 0; i < Math.min(decls.len, oNode.declarations.length); i++) {
        verifyDeclarator(decls.data + i * 40, oNode.declarations[i], `${p}.decl[${i}]`);
      }
      break;
    }
    case 'ExpressionStatement': {
      const exprOff = u32(off + 16);
      if (exprOff > 0 && oNode.expression) verifyExpr(exprOff, oNode.expression, `${p}.expr`);
      break;
    }
    case 'BlockStatement': {
      const bdy = dyn(off + 16);
      if (!Array.isArray(oNode.body)) break;
      eq(`${p}.body.len`, bdy.len, oNode.body.length);
      for (let i = 0; i < Math.min(bdy.len, oNode.body.length); i++) {
        const slotOff = bdy.data + i * 8;
        const su2Off = u32(slotOff);
        if (su2Off === 0) continue;
        const su2 = union(su2Off);
        verifyStmt(su2.ptr, STMT[su2.tag], oNode.body[i], `${p}.body[${i}]`);
      }
      break;
    }
    case 'ReturnStatement': {
      const argOff = u32(off + 16);
      if (argOff > 0 && oNode.argument) verifyExpr(argOff, oNode.argument, `${p}.argument`);
      break;
    }
    case 'IfStatement': {
      const testOff = u32(off + 16);
      if (testOff > 0 && oNode.test) verifyExpr(testOff, oNode.test, `${p}.test`);
      const cOff = u32(off + 24);
      if (cOff > 0 && oNode.consequent) {
        const cu = union(cOff);
        verifyStmt(cu.ptr, STMT[cu.tag], oNode.consequent, `${p}.consequent`);
      }
      const aOff = u32(off + 32);
      if (aOff > 0 && oNode.alternate) {
        const au = union(aOff);
        verifyStmt(au.ptr, STMT[au.tag], oNode.alternate, `${p}.alternate`);
      }
      break;
    }
    case 'WhileStatement': {
      const testOff = u32(off + 16);
      if (testOff > 0 && oNode.test) verifyExpr(testOff, oNode.test, `${p}.test`);
      const bodyOff = u32(off + 24);
      if (bodyOff > 0 && oNode.body) {
        const su = union(bodyOff);
        const sType = STMT[su.tag];
        verifyStmt(su.ptr, sType, oNode.body, `${p}.body`);
      }
      break;
    }
    case 'DoWhileStatement': {
      const bodyOff = u32(off + 16);
      if (bodyOff > 0 && oNode.body) {
        const su = union(bodyOff);
        const sType = STMT[su.tag];
        verifyStmt(su.ptr, sType, oNode.body, `${p}.body`);
      }
      const testOff = u32(off + 24);
      if (testOff > 0 && oNode.test) verifyExpr(testOff, oNode.test, `${p}.test`);
      break;
    }
    case 'ForStatement': {
      if (off + 56 > buf.length) break;
      const initDeclOff = u32(off + 16);
      const initExprOff = u32(off + 24);
      if (oNode.init) {
        if (initDeclOff > 0) {
          const su = union(initDeclOff);
          verifyStmt(su.ptr, STMT[su.tag], oNode.init, `${p}.init`);
        } else if (initExprOff > 0) {
          verifyExpr(initExprOff, oNode.init, `${p}.init`);
        }
      } else if (initDeclOff > 0 || initExprOff > 0) {
        fail(`${p}.init`, `kessel has init but oxc null`);
      }
      const testOff = u32(off + 32);
      if (testOff > 0 && oNode.test) verifyExpr(testOff, oNode.test, `${p}.test`);
      const updOff = u32(off + 40);
      if (updOff > 0 && oNode.update) verifyExpr(updOff, oNode.update, `${p}.update`);
      const bodyOff = u32(off + 48);
      if (bodyOff > 0 && oNode.body) {
        const su = union(bodyOff);
        verifyStmt(su.ptr, STMT[su.tag], oNode.body, `${p}.body`);
      }
      break;
    }
    case 'ForInStatement': {
      if (off + 48 > buf.length) break;
      const leftDeclOff = u32(off + 16);
      const leftExprOff = u32(off + 24);
      if (oNode.left) {
        if (leftDeclOff > 0) {
          const su = union(leftDeclOff);
          verifyStmt(su.ptr, STMT[su.tag], oNode.left, `${p}.left`);
        } else if (leftExprOff > 0) {
          verifyExpr(leftExprOff, oNode.left, `${p}.left`);
        }
      }
      const rightOff = u32(off + 32);
      if (rightOff > 0 && oNode.right) verifyExpr(rightOff, oNode.right, `${p}.right`);
      const bodyOff = u32(off + 40);
      if (bodyOff > 0 && oNode.body) {
        const su = union(bodyOff);
        verifyStmt(su.ptr, STMT[su.tag], oNode.body, `${p}.body`);
      }
      break;
    }
    case 'ForOfStatement': {
      if (off + 56 > buf.length) break;
      const leftDeclOff = u32(off + 16);
      const leftExprOff = u32(off + 24);
      if (oNode.left) {
        if (leftDeclOff > 0) {
          const su = union(leftDeclOff);
          verifyStmt(su.ptr, STMT[su.tag], oNode.left, `${p}.left`);
        } else if (leftExprOff > 0) {
          verifyExpr(leftExprOff, oNode.left, `${p}.left`);
        }
      }
      const rightOff = u32(off + 32);
      if (rightOff > 0 && oNode.right) verifyExpr(rightOff, oNode.right, `${p}.right`);
      const bodyOff = u32(off + 40);
      if (bodyOff > 0 && oNode.body) {
        const su = union(bodyOff);
        verifyStmt(su.ptr, STMT[su.tag], oNode.body, `${p}.body`);
      }
      eq(`${p}.await`, u8(off + 48) === 1, !!oNode.await);
      break;
    }
    case 'ThrowStatement': {
      const argOff = u32(off + 16);
      if (argOff > 0 && oNode.argument) verifyExpr(argOff, oNode.argument, `${p}.argument`);
      break;
    }
    case 'LabeledStatement': {
      eq(`${p}.label.name`, str(off + 32), oNode.label && oNode.label.name);
      const bodyOff = u32(off + 48);
      if (bodyOff > 0 && oNode.body) {
        const su = union(bodyOff);
        const sType = STMT[su.tag];
        verifyStmt(su.ptr, sType, oNode.body, `${p}.body`);
      }
      break;
    }
    case 'TryStatement': {
      // block is an INLINE BlockStatement at TryStatement offset 16.
      // Its body dyn-header is at +16+16 = +32.
      const bdy = dyn(off + 32);
      if (oNode.block && Array.isArray(oNode.block.body)) {
        eq(`${p}.block.len`, bdy.len, oNode.block.body.length);
        for (let i = 0; i < Math.min(bdy.len, oNode.block.body.length); i++) {
          const slotOff = bdy.data + i * 8;
          const stmtUOff = u32(slotOff);
          if (stmtUOff === 0) continue;
          const su = union(stmtUOff);
          const sType = STMT[su.tag];
          verifyStmt(su.ptr, sType, oNode.block.body[i], `${p}.block[${i}]`);
        }
      }
      // handler and finalizer are intentionally not recursed (Maybe layout out of scope).
      break;
    }
    case 'ClassDeclaration': {
      verifyClassDecl(off, oNode, p);
      break;
    }
    case 'TSInterfaceDeclaration': {
      // W5: id.name + extends.length + extends[0].expression name when
      // the JSON side reports an Identifier (qualified-parent shapes
      // resolve to MemberExpression in JSON; only assert the binary
      // union ptr is in-buffer in that case).
      eq(`${p}.id.name`, str(off + TSI_ID_NAME_OFF), oNode.id && oNode.id.name);
      const ext = dyn(off + TSI_EXTENDS_OFF);
      if (Array.isArray(oNode.extends)) {
        eq(`${p}.extends.length`, ext.len, oNode.extends.length);
        for (let i = 0; i < Math.min(ext.len, oNode.extends.length); i++) {
          const tih = ext.data + i * TSIH_SIZE;
          const exprUnionOff = u32(tih + TSIH_EXPRESSION_OFF);
          if (oNode.extends[i].expression && oNode.extends[i].expression.type === 'Identifier' && exprUnionOff > 0) {
            verifyExpr(exprUnionOff, oNode.extends[i].expression, `${p}.extends[${i}].expression`);
          }
        }
      }
      break;
    }
    case 'TSTypeAliasDeclaration': {
      eq(`${p}.id.name`, str(off + TSA_ID_NAME_OFF), oNode.id && oNode.id.name);
      break;
    }
    case 'TSEnumDeclaration': {
      eq(`${p}.id.name`, str(off + TSE_ID_NAME_OFF), oNode.id && oNode.id.name);
      // OXC sometimes nests members under .body.members, sometimes under
      // .members directly depending on plugin/version. Accept either.
      const oxcMembers = (oNode.body && oNode.body.members) || oNode.members || [];
      const members = dyn(off + TSE_BODY_MEMBERS_OFF);
      eq(`${p}.body.members.length`, members.len, oxcMembers.length);
      for (let i = 0; i < Math.min(members.len, oxcMembers.length); i++) {
        const mOff = members.data + i * TSEM_SIZE;
        const idUnionOff = u32(mOff + TSEM_ID_OFF);
        if (idUnionOff > 0 && oxcMembers[i].id) {
          verifyExpr(idUnionOff, oxcMembers[i].id, `${p}.members[${i}].id`);
        }
      }
      break;
    }
    case 'TSModuleDeclaration': {
      // The binary path does NOT fold qualified namespace ids (`namespace A.B`);
      // the JSON path does. Only assert id resolves into the buffer; deep
      // shape parity is the dedicated W3 verifier's job.
      const idUnionOff = u32(off + TSM_ID_OFF);
      if (idUnionOff === 0 || idUnionOff >= buf.length) {
        fail(`${p}.id`, `union ptr ${idUnionOff} out of buffer`);
      } else {
        ok(`${p}.id`);
      }
      // body is Maybe(^TSModuleBody): zero means absent (`namespace A;`),
      // non-zero must be in-buffer.
      const bodyVal = u32(off + TSM_BODY_OFF);
      if (oNode.body) {
        if (bodyVal === 0 || bodyVal >= buf.length) {
          fail(`${p}.body`, `expected set, got ${bodyVal}`);
        } else {
          ok(`${p}.body`);
        }
      }
      break;
    }
    case 'FunctionDeclaration':
    case 'FunctionExpression_Stmt': {
      // FunctionDeclaration uses `using expr: FunctionExpression`, same
      // layout. Body (FunctionBody) starts at offset 96; its .body
      // dyn-header sits at +96+16 = +112.
      const s = u32(off), e = u32(off+4);
      // Spans are byte offsets, source.length is UTF-16 code units —
      // use sourceBuf.length so non-ASCII content (e.g. emoji or arrows in
      // comments) doesn't trip a false-positive span end check.
      if (s <= e && e <= sourceBuf.length) ok(`${p}.span`);
      else fail(`${p}.span`, `${s}-${e}`);
      const bdy = dyn(off + 112);
      if (oNode.body && Array.isArray(oNode.body.body)) {
        eq(`${p}.body.len`, bdy.len, oNode.body.body.length);
        for (let i = 0; i < Math.min(bdy.len, oNode.body.body.length); i++) {
          const slotOff = bdy.data + i * 8;
          const su2Off = u32(slotOff);
          if (su2Off === 0) continue;
          const su2 = union(su2Off);
          verifyStmt(su2.ptr, STMT[su2.tag], oNode.body.body[i], `${p}.body[${i}]`);
        }
      }
      eq(`${p}.generator`, u8(off + 192) === 1, !!oNode.generator);
      eq(`${p}.async`, u8(off + 193) === 1, !!oNode.async);
      break;
    }
    // Add more as needed
  }
}

function verifyDeclarator(off, oNode, p) {
  // id at offset 16 (Pattern union)
  const idU = union(off + 16);
  if (idU.tag === 1 && oNode.id && oNode.id.type === 'Identifier') {
    // Identifier name at ptr + 16
    eq(`${p}.id.name`, str(idU.ptr + 16), oNode.id.name);
  }
  // init at offset 32
  const initOff = u32(off + 32);
  if (initOff > 0 && oNode.init) verifyExpr(initOff, oNode.init, `${p}.init`);
}

function verifyExpr(unionOff, oNode, p) {
  if (unionOff === 0 || unionOff >= buf.length || !oNode) return;
  const eu = union(unionOff);
  const kType = EXPR[eu.tag];
  if (!kType) { fail(`${p}.type`, `unknown tag ${eu.tag}`); return; }
  eq(`${p}.type`, normalizeType(kType), oNode.type);

  const off = eu.ptr;
  if (off === 0 || off >= buf.length) return;

  switch (kType) {
    case 'Identifier':
      eq(`${p}.name`, str(off + 16), oNode.name);
      break;
    case 'NumericLiteral':
      eq(`${p}.value`, f64(off + 16), oNode.value);
      eq(`${p}.raw`, str(off + 24), oNode.raw);
      break;
    case 'StringLiteral':
      eq(`${p}.value`, str(off + 16), oNode.value);
      eq(`${p}.raw`, str(off + 32), oNode.raw);
      break;
    case 'BooleanLiteral':
      eq(`${p}.value`, u8(off + 16) === 1, oNode.value);
      break;
    case 'NullLiteral':
      eq(`${p}.value`, null, oNode.value);
      break;
    case 'BigIntLiteral':
      eq(`${p}.raw`, str(off + 32), oNode.raw);
      break;
    case 'BinaryExpression': {
      eq(`${p}.operator`, BIN_OP[u32(off + 16)], oNode.operator);
      const lOff = u32(off + 24), rOff = u32(off + 32);
      if (lOff > 0 && oNode.left) verifyExpr(lOff, oNode.left, `${p}.left`);
      if (rOff > 0 && oNode.right) verifyExpr(rOff, oNode.right, `${p}.right`);
      break;
    }
    case 'LogicalExpression': {
      eq(`${p}.operator`, LOG_OP[u32(off + 16)], oNode.operator);
      const lOff = u32(off + 24), rOff = u32(off + 32);
      if (lOff > 0 && oNode.left) verifyExpr(lOff, oNode.left, `${p}.left`);
      if (rOff > 0 && oNode.right) verifyExpr(rOff, oNode.right, `${p}.right`);
      break;
    }
    case 'AssignmentExpression': {
      eq(`${p}.operator`, ASN_OP[u32(off + 16)], oNode.operator);
      const lOff = u32(off + 24), rOff = u32(off + 32);
      if (lOff > 0 && oNode.left) verifyExpr(lOff, oNode.left, `${p}.left`);
      if (rOff > 0 && oNode.right) verifyExpr(rOff, oNode.right, `${p}.right`);
      break;
    }
    case 'MemberExpression': {
      const objOff = u32(off + 16), propOff = u32(off + 24);
      if (objOff > 0 && oNode.object) verifyExpr(objOff, oNode.object, `${p}.object`);
      if (propOff > 0 && oNode.property) verifyExpr(propOff, oNode.property, `${p}.property`);
      break;
    }
    case 'CallExpression': {
      const calleeOff = u32(off + 16);
      if (calleeOff > 0 && oNode.callee) verifyExpr(calleeOff, oNode.callee, `${p}.callee`);
      const args = dyn(off + 24);
      if (!Array.isArray(oNode.arguments)) break;
      eq(`${p}.args.len`, args.len, oNode.arguments.length);
      for (let i = 0; i < Math.min(args.len, oNode.arguments.length); i++) {
        const argOff = u32(args.data + i * 8);
        if (argOff > 0 && oNode.arguments[i]) verifyExpr(argOff, oNode.arguments[i], `${p}.arguments[${i}]`);
      }
      break;
    }
    case 'NewExpression': {
      const calleeOff = u32(off + 16);
      if (calleeOff > 0 && oNode.callee) verifyExpr(calleeOff, oNode.callee, `${p}.callee`);
      const args = dyn(off + 24);
      if (!Array.isArray(oNode.arguments)) break;
      eq(`${p}.args.len`, args.len, oNode.arguments.length);
      for (let i = 0; i < Math.min(args.len, oNode.arguments.length); i++) {
        const argOff = u32(args.data + i * 8);
        if (argOff > 0 && oNode.arguments[i]) verifyExpr(argOff, oNode.arguments[i], `${p}.arguments[${i}]`);
      }
      break;
    }
    case 'UnaryExpression': {
      eq(`${p}.operator`, UN_OP[u32(off + 16)], oNode.operator);
      const argOff = u32(off + 24);
      if (argOff > 0 && oNode.argument) verifyExpr(argOff, oNode.argument, `${p}.argument`);
      break;
    }
    case 'UpdateExpression': {
      eq(`${p}.operator`, UPD_OP[u32(off + 16)], oNode.operator);
      const argOff = u32(off + 24);
      if (argOff > 0 && oNode.argument) verifyExpr(argOff, oNode.argument, `${p}.argument`);
      break;
    }
    case 'FunctionExpression': {
      // body@96, FunctionBody.body dyn-header @ +96+16 = +112
      const bdy = dyn(off + 112);
      if (oNode.body && Array.isArray(oNode.body.body)) {
        eq(`${p}.body.len`, bdy.len, oNode.body.body.length);
        for (let i = 0; i < Math.min(bdy.len, oNode.body.body.length); i++) {
          const slotOff = bdy.data + i * 8;
          const suOff = u32(slotOff);
          if (suOff === 0) continue;
          const su = union(suOff);
          verifyStmt(su.ptr, STMT[su.tag], oNode.body.body[i], `${p}.body[${i}]`);
        }
      }
      eq(`${p}.generator`, u8(off + 192) === 1, !!oNode.generator);
      eq(`${p}.async`, u8(off + 193) === 1, !!oNode.async);
      break;
    }
    case 'ArrowFunctionExpression': {
      // body recursion skipped in this task (union polymorphism).
      eq(`${p}.expression`, u8(off + 64) === 1, !!oNode.expression);
      eq(`${p}.async`, u8(off + 65) === 1, !!oNode.async);
      break;
    }
    case 'SpreadElement':
    case 'AwaitExpression': {
      const argOff = u32(off + 16);
      if (argOff > 0 && oNode.argument) verifyExpr(argOff, oNode.argument, `${p}.argument`);
      break;
    }
    case 'ConditionalExpression': {
      const tOff = u32(off + 16), cOff = u32(off + 24), aOff = u32(off + 32);
      if (tOff > 0 && oNode.test) verifyExpr(tOff, oNode.test, `${p}.test`);
      if (cOff > 0 && oNode.consequent) verifyExpr(cOff, oNode.consequent, `${p}.consequent`);
      if (aOff > 0 && oNode.alternate) verifyExpr(aOff, oNode.alternate, `${p}.alternate`);
      break;
    }
    case 'ArrayExpression': {
      const elems = dyn(off + 16);
      if (oNode.elements) {
        eq(`${p}.elements.len`, elems.len, oNode.elements.length);
        for (let i = 0; i < Math.min(elems.len, oNode.elements.length); i++) {
          const elOff = u32(elems.data + i * 8);
          if (elOff > 0) {
            if (oNode.elements[i]) verifyExpr(elOff, oNode.elements[i], `${p}.elements[${i}]`);
          } else if (oNode.elements[i] !== null) {
            fail(`${p}.elements[${i}]`, 'expected null');
          }
        }
      }
      break;
    }
    case 'ObjectExpression': {
      // Property struct in Odin is 48 bytes (PropertyKind enum = int = 8B on 64-bit).
      // Fields: loc@0-15, key@16, value@24, kind@32 (8B), computed@40, shorthand@41.
      const props = dyn(off + 16);
      if (oNode.properties) {
        eq(`${p}.properties.len`, props.len, oNode.properties.length);
        for (let i = 0; i < Math.min(props.len, oNode.properties.length); i++) {
          const propSlot = props.data + i * 48;
          const oProp = oNode.properties[i];
          if (oProp && oProp.type === 'Property') {
            const kind = u32(propSlot + 32);
            eq(`${p}.properties[${i}].kind`, PROP_KIND[kind], oProp.kind);
            eq(`${p}.properties[${i}].computed`, u8(propSlot + 40) === 1, oProp.computed);
            eq(`${p}.properties[${i}].shorthand`, u8(propSlot + 41) === 1, oProp.shorthand);
            const keyOff = u32(propSlot + 16);
            if (keyOff > 0 && oProp.key) verifyExpr(keyOff, oProp.key, `${p}.properties[${i}].key`);
            const valueOff = u32(propSlot + 24);
            if (valueOff > 0 && oProp.value) verifyExpr(valueOff, oProp.value, `${p}.properties[${i}].value`);
          }
        }
      }
      break;
    }
    case 'ThisExpression':
    case 'Super':
      // No fields to verify
      ok(`${p}`);
      break;
    // ====================================================================
    // W5: JSX, ChainExpression, TS-expression variants, Parens, Templates.
    // ====================================================================
    case 'JSXElement': {
      verifyJSXElement(off, oNode, p);
      break;
    }
    case 'JSXFragment': {
      const children = dyn(off + JSXFRAG_CHILDREN_OFF);
      if (Array.isArray(oNode.children)) {
        eq(`${p}.children.length`, children.len, oNode.children.length);
        for (let i = 0; i < Math.min(children.len, oNode.children.length); i++) {
          verifyJSXChild(children.data + i * JSXCHILD_SIZE, oNode.children[i], `${p}.children[${i}]`);
        }
      }
      break;
    }
    case 'JSXExpressionContainer': {
      const exprUOff = u32(off + JSXEC_EXPRESSION_OFF);
      if (exprUOff > 0 && oNode.expression && oNode.expression.type !== 'JSXEmptyExpression') {
        verifyExpr(exprUOff, oNode.expression, `${p}.expression`);
      }
      break;
    }
    case 'ChainExpression': {
      const exprUOff = u32(off + CHAIN_EXPRESSION_OFF);
      if (exprUOff > 0 && oNode.expression) verifyExpr(exprUOff, oNode.expression, `${p}.expression`);
      break;
    }
    case 'ParenthesizedExpression': {
      const exprUOff = u32(off + PAREN_EXPRESSION_OFF);
      if (exprUOff > 0 && oNode.expression) verifyExpr(exprUOff, oNode.expression, `${p}.expression`);
      break;
    }
    case 'TSAsExpression':
    case 'TSSatisfiesExpression':
    case 'TSNonNullExpression': {
      // Same shape: expression@+16, type_annotation (when present)@+24.
      const innerOff = u32(off + TS_AS_EXPRESSION_OFF);
      if (innerOff > 0 && oNode.expression) verifyExpr(innerOff, oNode.expression, `${p}.expression`);
      break;
    }
    case 'TSTypeAssertion': {
      // The odd one: type_annotation@+16, expression@+24 (TS surface
      // mirrors the textual `<Type>expr` order).
      const innerOff = u32(off + TS_ASSERTION_EXPRESSION_OFF);
      if (innerOff > 0 && oNode.expression) verifyExpr(innerOff, oNode.expression, `${p}.expression`);
      break;
    }
    case 'TaggedTemplateExpression': {
      const tagOff = u32(off + TT_TAG_OFF);
      if (tagOff > 0 && oNode.tag) verifyExpr(tagOff, oNode.tag, `${p}.tag`);
      const quasiOff = u32(off + TT_QUASI_OFF);
      if (quasiOff > 0 && oNode.quasi) verifyExpr(quasiOff, oNode.quasi, `${p}.quasi`);
      break;
    }
    case 'TemplateLiteral': {
      // quasis count + expressions count; deep shape parity (cooked/raw,
      // tail flags) is covered by verify_json_deep.
      const quasis = dyn(off + TPL_QUASIS_OFF);
      if (Array.isArray(oNode.quasis)) eq(`${p}.quasis.length`, quasis.len, oNode.quasis.length);
      const exprs = dyn(off + TPL_EXPRS_OFF);
      if (Array.isArray(oNode.expressions)) {
        eq(`${p}.expressions.length`, exprs.len, oNode.expressions.length);
        for (let i = 0; i < Math.min(exprs.len, oNode.expressions.length); i++) {
          const eOff = u32(exprs.data + i * 8);
          if (eOff > 0 && oNode.expressions[i]) verifyExpr(eOff, oNode.expressions[i], `${p}.expressions[${i}]`);
        }
      }
      break;
    }
  }
}

// ============================================================
// W5 helpers: ClassDeclaration body walk and JSX element/child walks.
// Factored out of verifyStmt/verifyExpr so the switches stay readable
// (and to keep individual functions under the 70-line TigerStyle
// guideline).
// ============================================================

function verifyClassDecl(off, oNode, p) {
  // id.name when present (anonymous class declarations use ClassExpression
  // semantics where id is null; ClassDeclaration always has an id).
  if (oNode.id && typeof oNode.id.name === 'string') {
    eq(`${p}.id.name`, str(off + CE_ID_NAME_OFF), oNode.id.name);
  }
  // class-level decorators — exercises S26 W1 binary plumbing.
  const classDecs = dyn(off + CE_DECORATORS_OFF);
  const oDecs = oNode.decorators || [];
  if (oDecs.length > 0 || classDecs.len > 0) {
    eq(`${p}.decorators.length`, classDecs.len, oDecs.length);
    for (let i = 0; i < Math.min(classDecs.len, oDecs.length); i++) {
      const decOff = classDecs.data + i * DECOR_SIZE;
      const exprUOff = u32(decOff + DECOR_EXPR_OFF);
      if (exprUOff > 0 && oDecs[i].expression) {
        verifyExpr(exprUOff, oDecs[i].expression, `${p}.decorators[${i}].expression`);
      }
    }
  }
  // body methods — recurse keys, decorators, and method-body FunctionExpressions.
  const body = dyn(off + CE_BODY_BODY_OFF);
  const oBody = (oNode.body && Array.isArray(oNode.body.body)) ? oNode.body.body : [];
  eq(`${p}.body.body.length`, body.len, oBody.length);
  for (let i = 0; i < Math.min(body.len, oBody.length); i++) {
    verifyClassElement(body.data + i * CELEM_SIZE, oBody[i], `${p}.body[${i}]`);
  }
}

function verifyClassElement(elemOff, oNode, p) {
  // key — Identifier / StringLiteral / NumericLiteral / computed expr.
  const keyUOff = u32(elemOff + CELEM_KEY_OFF);
  if (keyUOff > 0 && oNode.key) verifyExpr(keyUOff, oNode.key, `${p}.key`);
  // per-element decorators — exercises S26 W1 method-decorator plumbing.
  const elemDecs = dyn(elemOff + CELEM_DECORATORS_OFF);
  const oDecs = oNode.decorators || [];
  if (oDecs.length > 0 || elemDecs.len > 0) {
    eq(`${p}.decorators.length`, elemDecs.len, oDecs.length);
    for (let d = 0; d < Math.min(elemDecs.len, oDecs.length); d++) {
      const decOff = elemDecs.data + d * DECOR_SIZE;
      const exprUOff = u32(decOff + DECOR_EXPR_OFF);
      if (exprUOff > 0 && oDecs[d].expression) {
        verifyExpr(exprUOff, oDecs[d].expression, `${p}.decorators[${d}].expression`);
      }
    }
  }
  // value — MethodDefinition.value is FunctionExpression; PropertyDefinition
  // .value is Maybe(Expression). Either path lands on verifyExpr which
  // handles FunctionExpression bodies in the existing walker.
  const valueUOff = u32(elemOff + CELEM_VALUE_OFF);
  if (valueUOff > 0 && oNode.value) verifyExpr(valueUOff, oNode.value, `${p}.value`);
}

function verifyJSXElement(elemOff, oNode, p) {
  // opening_element.name (only assert when the JSXElementName union is a
  // JSXIdentifier; member/namespaced shapes are validated structurally
  // by verify_json_deep).
  const openingOff = u32(elemOff + JSXE_OPENING_OFF);
  if (openingOff > 0 && oNode.openingElement && oNode.openingElement.name) {
    const nameTag = u8(openingOff + JSXOE_NAME_OFF + JSXNAME_TAG_OFF);
    if (nameTag === JSXNAME_TAG_IDENT && oNode.openingElement.name.type === 'JSXIdentifier') {
      eq(`${p}.openingElement.name.name`,
         str(openingOff + JSXOE_NAME_OFF + JSXID_NAME_OFF),
         oNode.openingElement.name.name);
    }
  }
  // children
  const children = dyn(elemOff + JSXE_CHILDREN_OFF);
  if (Array.isArray(oNode.children)) {
    eq(`${p}.children.length`, children.len, oNode.children.length);
    for (let i = 0; i < Math.min(children.len, oNode.children.length); i++) {
      verifyJSXChild(children.data + i * JSXCHILD_SIZE, oNode.children[i], `${p}.children[${i}]`);
    }
  }
}

function verifyJSXChild(slotOff, oNode, p) {
  if (!oNode) return;
  const ptr = u32(slotOff);
  const tag = u8(slotOff + 8);
  if (ptr === 0 || ptr >= buf.length) return;
  if (tag === JSXCHILD_TAG_ELEMENT && oNode.type === 'JSXElement') {
    verifyJSXElement(ptr, oNode, p);
  } else if (tag === JSXCHILD_TAG_FRAGMENT && oNode.type === 'JSXFragment') {
    // JSXFragment has children at +32 (after loc + opening_fragment value).
    const children = dyn(ptr + JSXFRAG_CHILDREN_OFF);
    if (Array.isArray(oNode.children)) {
      eq(`${p}.children.length`, children.len, oNode.children.length);
      for (let i = 0; i < Math.min(children.len, oNode.children.length); i++) {
        verifyJSXChild(children.data + i * JSXCHILD_SIZE, oNode.children[i], `${p}.children[${i}]`);
      }
    }
  } else if (tag === JSXCHILD_TAG_EXPRCONT && oNode.type === 'JSXExpressionContainer') {
    const exprUOff = u32(ptr + JSXEC_EXPRESSION_OFF);
    if (exprUOff > 0 && oNode.expression && oNode.expression.type !== 'JSXEmptyExpression') {
      verifyExpr(exprUOff, oNode.expression, `${p}.expression`);
    }
  }
  // JSXText / JSXSpreadChild leaves: no recursion in this walker; deep
  // shape (value/raw on text, spread argument) is covered by
  // verify_json_deep.
}

// Run
console.log(`Verifying: ${name} (${sourceBuf.length} bytes)`);
console.log(`  OXC parseSync: ${oxcAst.body.length} top-level statements`);

verifyProgram();

console.log(`  Fields matched: ${matched}`);

// ---------------------------------------------------------------------------
// Exit policy.
// ---------------------------------------------------------------------------
// Three modes, chosen by CLI flags:
//   - `--update`   : write current mismatch count into the baseline file
//                    keyed by `baselineKey` and exit 0.
//   - `--baseline` : compare `errors` to the baselined value for this file.
//                    Equal or lower passes; higher is a regression (exit 1).
//                    A decrease is reported as an improvement so it can be
//                    locked in with --update, matching verify_spec_compliance.
//   - neither      : zero-tolerance. Any mismatch fails. This is the
//                    original behaviour and the default.
function readBaseline() {
  if (!fs.existsSync(BASELINE_PATH)) return {};
  try {
    const raw = fs.readFileSync(BASELINE_PATH, 'utf8');
    const parsed = JSON.parse(raw);
    return (parsed && typeof parsed === 'object') ? parsed : {};
  } catch (err) {
    console.error(`  baseline unreadable: ${err.message}`);
    process.exit(2);
  }
}

function writeBaseline(obj) {
  // Keys sorted so the file is stable across runs and reviewable in a diff.
  const sorted = {};
  for (const k of Object.keys(obj).sort()) sorted[k] = obj[k];
  fs.mkdirSync(path.dirname(BASELINE_PATH), { recursive: true });
  fs.writeFileSync(BASELINE_PATH, JSON.stringify(sorted, null, 2) + '\n');
}

if (UPDATE) {
  const baseline = readBaseline();
  const prev = baseline[baselineKey];
  baseline[baselineKey] = errors;
  writeBaseline(baseline);
  if (prev === undefined) {
    console.log(`  Baseline created: ${baselineKey} -> ${errors}`);
  } else if (prev !== errors) {
    const verb = errors > prev ? 'REGRESSED' : 'IMPROVED';
    console.log(`  Baseline updated: ${baselineKey} ${prev} -> ${errors} (${verb})`);
  } else {
    console.log(`  Baseline unchanged: ${baselineKey} stays at ${errors}`);
  }
  process.exit(0);
}

if (BASELINE_MODE) {
  const baseline = readBaseline();
  const prev = baseline[baselineKey];
  if (prev === undefined) {
    console.log(`  ❌ no baseline entry for ${baselineKey} — run with --update to create one`);
    process.exit(1);
  }
  if (errors > prev) {
    console.log(`  ❌ ${errors} mismatches (baseline ${prev}, REGRESSED by ${errors - prev})`);
    process.exit(1);
  }
  if (errors < prev) {
    console.log(`  ✅ ${errors} mismatches (baseline ${prev}, improved by ${prev - errors})`);
    console.log('  Run with --update to lock the improvement in.');
    process.exit(0);
  }
  console.log(`  ✅ ${errors} mismatches (baseline)`);
  process.exit(0);
}

// Strict mode (original behaviour): any mismatch fails.
if (errors > 0) {
  console.log(`  ❌ ${errors} mismatches`);
  process.exit(1);
} else {
  console.log(`  ✅ Kessel raw transfer matches OXC`);
}
