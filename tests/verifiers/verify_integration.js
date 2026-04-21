#!/usr/bin/env node
// Integration verification: parse with OXC (source of truth) and Kessel raw,
// walk both ASTs and compare structure + values.
//
// Usage: node verify_integration.js <file.js> [--verbose]

const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');
const { parseSync } = require(path.resolve(__dirname, '../../bench/node_modules/oxc-parser'));

const file = process.argv[2];
const verbose = process.argv.includes('--verbose');
if (!file) { console.error('Usage: node verify_integration.js <file.js>'); process.exit(1); }

const kesselBin = path.resolve(__dirname, '../../bin/kessel');
const source = fs.readFileSync(file, 'utf8');
const name = path.basename(file);

// ============================================================
// OXC: parse (source of truth)
// ============================================================
const oxc = parseSync(name, source, { preserveParens: false });
const oxcAst = oxc.program;

// ============================================================
// Kessel: raw transfer
// ============================================================
execSync(`${kesselBin} raw "${file}" --out /tmp/_verify_integ.bin`, { stdio: 'pipe' });
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

// Tag → type name mappings (from ast.odin union order)
const EXPR = { 1:'NullLiteral',2:'BooleanLiteral',3:'NumericLiteral',4:'StringLiteral',
  5:'BigIntLiteral',6:'RegExpLiteral',7:'TemplateLiteral',8:'TaggedTemplateExpression',
  9:'Identifier',10:'PrivateIdentifier',11:'ThisExpression',12:'Super',
  13:'ArrayExpression',14:'ObjectExpression',15:'FunctionExpression',
  16:'ArrowFunctionExpression',17:'ClassExpression',18:'MemberExpression',
  19:'CallExpression',20:'NewExpression',21:'ConditionalExpression',
  22:'UpdateExpression',23:'UnaryExpression',24:'BinaryExpression',
  25:'LogicalExpression',26:'AssignmentExpression',27:'SequenceExpression',
  28:'SpreadElement',29:'YieldExpression',30:'AwaitExpression',
  31:'ImportExpression',32:'MetaProperty' };

const STMT = { 1:'ExpressionStatement',2:'EmptyStatement',3:'BlockStatement',
  4:'DebuggerStatement',5:'ReturnStatement',6:'BreakStatement',
  7:'ContinueStatement',8:'LabeledStatement',9:'IfStatement',
  10:'SwitchStatement',11:'WhileStatement',12:'DoWhileStatement',
  13:'ForStatement',14:'ForInStatement',15:'ForOfStatement',
  16:'WithStatement',17:'ThrowStatement',18:'TryStatement',
  19:'FunctionDeclaration',20:'VariableDeclaration',21:'ClassDeclaration',
  22:'ImportDeclaration',23:'ExportNamedDeclaration',24:'ExportDefaultDeclaration',
  25:'ExportAllDeclaration' };

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
    case 'FunctionDeclaration':
    case 'FunctionExpression_Stmt': {
      // FunctionDeclaration uses `using expr: FunctionExpression`, same
      // layout. Body (FunctionBody) starts at offset 96; its .body
      // dyn-header sits at +96+16 = +112.
      const s = u32(off), e = u32(off+4);
      if (s <= e && e <= source.length) ok(`${p}.span`);
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
  }
}

// Run
console.log(`Verifying: ${name} (${source.length} bytes)`);
console.log(`  OXC parseSync: ${oxcAst.body.length} top-level statements`);

verifyProgram();

console.log(`  Fields matched: ${matched}`);
if (errors > 0) {
  console.log(`  ❌ ${errors} mismatches`);
  process.exit(1);
} else {
  console.log(`  ✅ Kessel raw transfer matches OXC`);
}
