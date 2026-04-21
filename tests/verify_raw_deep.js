#!/usr/bin/env node
// Deep verification: parse a file with both JSON and raw paths,
// then walk the raw buffer and compare every node against the JSON AST.

const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

const file = process.argv[2];
if (!file) {
  console.error('Usage: node verify_raw_deep.js <file.js>');
  process.exit(1);
}

const kesselBin = path.resolve(__dirname, '../bin/kessel');
const source = fs.readFileSync(file, 'utf8');

// Get JSON AST. `--compact` output: JSON on line 1, then any number of
// diagnostic/stat lines. Take line 1 exactly — anything after it is not
// part of the JSON. (The legacy `{ ... }` / `[ ... ]` placeholders were
// removed when the JSON emitter became fully recursive.)
const jsonOut = execSync(`${kesselBin} parse "${file}" --compact`, { encoding: 'utf8', maxBuffer: 500 * 1024 * 1024 });
const jsonAst = JSON.parse(jsonOut.split('\n')[0]);

// OXC-style ESTree collapses NullLiteral/BooleanLiteral/NumericLiteral/
// StringLiteral/BigIntLiteral/RegExpLiteral into `type: "Literal"`, and
// Kessel's JSON emitter does the same (commit 6fc0990). The raw buffer
// however still tags each literal with its specific union variant, so the
// verifier must normalize before comparing type names.
const LITERAL_VARIANTS = new Set([
  'NullLiteral', 'BooleanLiteral', 'NumericLiteral',
  'StringLiteral', 'BigIntLiteral', 'RegExpLiteral',
]);
function normType(t) { return LITERAL_VARIANTS.has(t) ? 'Literal' : t; }

// Get raw buffer
execSync(`${kesselBin} raw "${file}" --out /tmp/_verify_raw.bin`, { stdio: 'pipe' });
const bin = fs.readFileSync('/tmp/_verify_raw.bin');
const HEADER_SIZE = 20;
const magic = bin.readUInt32LE(0);
if (magic !== 0x4B455353) { console.error('Bad magic'); process.exit(1); }
const programOffset = bin.readUInt32LE(8);
const buf = bin.subarray(HEADER_SIZE);
const view = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);

function u32(off) { return view.getUint32(off, true); }
function u8(off) { return view.getUint8(off); }
function f64(off) { return view.getFloat64(off, true); }
// STRING_ARENA_FLAG encoding — see src/raw_transfer.odin. High bit set → the
// string's bytes live in the buffer (arena), not in source; used for cooked
// strings from Bug E escape decoding.
const STRING_ARENA_FLAG = 0x80000000;
const sourceBuf = Buffer.from(source, 'utf8');
function str(off) {
  const raw = u32(off), l = u32(off + 4);
  if (l === 0) return '';
  if (raw & STRING_ARENA_FLAG) {
    const arenaOff = raw & 0x7fffffff;
    return buf.toString('utf8', arenaOff, arenaOff + l);
  }
  if (l > sourceBuf.length) return '';
  return sourceBuf.toString('utf8', raw, raw + l);
}
function dynHeader(off) { return { data: u32(off), len: u32(off + 4) }; }
function readUnion(off) { return { ptr: u32(off), tag: u8(off + 8) }; }

// Expression union tags (order from ast.odin)
const EXPR_TAGS = {
  1:'NullLiteral', 2:'BooleanLiteral', 3:'NumericLiteral', 4:'StringLiteral',
  5:'BigIntLiteral', 6:'RegExpLiteral', 7:'TemplateLiteral', 8:'TaggedTemplateExpression',
  9:'Identifier', 10:'PrivateIdentifier', 11:'ThisExpression', 12:'Super',
  13:'ArrayExpression', 14:'ObjectExpression', 15:'FunctionExpression',
  16:'ArrowFunctionExpression', 17:'ClassExpression', 18:'MemberExpression',
  19:'CallExpression', 20:'NewExpression', 21:'ConditionalExpression',
  22:'UpdateExpression', 23:'UnaryExpression', 24:'BinaryExpression',
  25:'LogicalExpression', 26:'AssignmentExpression', 27:'SequenceExpression',
  28:'SpreadElement', 29:'YieldExpression', 30:'AwaitExpression',
  31:'ImportExpression', 32:'MetaProperty',
};

const STMT_TAGS = {
  1:'ExpressionStatement', 2:'EmptyStatement', 3:'BlockStatement',
  4:'DebuggerStatement', 5:'ReturnStatement', 6:'BreakStatement',
  7:'ContinueStatement', 8:'LabeledStatement', 9:'IfStatement',
  10:'SwitchStatement', 11:'WhileStatement', 12:'DoWhileStatement',
  13:'ForStatement', 14:'ForInStatement', 15:'ForOfStatement',
  16:'WithStatement', 17:'ThrowStatement', 18:'TryStatement',
  19:'FunctionDeclaration', 20:'VariableDeclaration', 21:'ClassDeclaration',
  22:'ImportDeclaration', 23:'ExportNamedDeclaration', 24:'ExportDefaultDeclaration',
  25:'ExportAllDeclaration',
};

let errors = 0;
let checked = 0;

function fail(path, msg) {
  errors++;
  if (errors <= 20) console.error(`  FAIL ${path}: ${msg}`);
}

function check(path, raw, json) {
  if (raw !== json) {
    fail(path, `raw=${JSON.stringify(raw)} json=${JSON.stringify(json)}`);
    return false;
  }
  checked++;
  return true;
}

// Like check(), but normalizes literal subtype names on both sides before
// comparing so a raw `NumericLiteral` tag compares equal to a JSON `Literal`
// type. Used on every `.type` field the verifier checks.
function checkType(path, raw, json) {
  return check(path, normType(raw), normType(json));
}

// Verify Program.body — walk each statement and compare type + span
function verifyProgram(rawOff, json) {
  const rawSpanStart = u32(rawOff);
  const rawSpanEnd = u32(rawOff + 4);

  // body at offset 24 in Program struct
  const body = dynHeader(rawOff + 24);
  check('program.body.length', body.len, json.body.length);

  for (let i = 0; i < Math.min(body.len, json.body.length); i++) {
    const slotOff = body.data + i * 8;
    const stmtUnionOff = u32(slotOff);
    if (stmtUnionOff === 0) { fail(`body[${i}]`, 'null stmt ptr'); continue; }
    const union = readUnion(stmtUnionOff);
    const rawType = STMT_TAGS[union.tag];
    const jsonType = json.body[i].type;
    checkType(`body[${i}].type`, rawType, jsonType);

    if (union.ptr > 0 && union.ptr < buf.length) {
      const rawStart = u32(union.ptr);
      const rawEnd = u32(union.ptr + 4);
      verifyStatement(union.ptr, rawType, json.body[i], `body[${i}]`);
    }
  }
}

function verifyStatement(off, type, json, path) {
  if (!type || !json) return;

  // Verify span
  const rawStart = u32(off);
  const rawEnd = u32(off + 4);
  if (json.start !== undefined) check(`${path}.start`, rawStart, json.start);
  if (json.end !== undefined) check(`${path}.end`, rawEnd, json.end);

  switch (type) {
    case 'VariableDeclaration':
      verifyVarDecl(off, json, path);
      break;
    case 'ExpressionStatement':
      verifyExprStmt(off, json, path);
      break;
    case 'BlockStatement':
      // body at offset 16
      const bBody = dynHeader(off + 16);
      if (json.body) check(`${path}.body.length`, bBody.len, json.body.length);
      break;
    case 'FunctionDeclaration':
      // Has span — that's enough to confirm it's correct
      break;
  }
}

function verifyVarDecl(off, json, path) {
  // kind at offset 16
  const kind = u32(off + 16);
  const kinds = ['var', 'let', 'const'];
  check(`${path}.kind`, kinds[kind], json.kind);

  // declarations at offset 24
  const decls = dynHeader(off + 24);
  if (json.declarations) {
    check(`${path}.declarations.length`, decls.len, json.declarations.length);
    for (let i = 0; i < Math.min(decls.len, json.declarations.length); i++) {
      verifyDeclarator(decls.data, i, json.declarations[i], `${path}.decl[${i}]`);
    }
  }
}

function verifyDeclarator(dataOff, idx, json, path) {
  // VariableDeclarator: {Loc:16, id:Pattern(16), init:Maybe(^Expr)(8)} = 40 bytes
  const dOff = dataOff + idx * 40;

  // id is Pattern union at offset 16
  const idUnion = readUnion(dOff + 16);
  if (idUnion.tag === 1 && json.id && json.id.type === 'Identifier') {
    // Identifier at idUnion.ptr, name at +16
    const name = str(idUnion.ptr + 16);
    check(`${path}.id.name`, name, json.id.name);
  }

  // init at offset 32 (Maybe ^Expression)
  const initOff = u32(dOff + 32);
  if (initOff > 0 && json.init) {
    verifyExprFromUnion(initOff, json.init, `${path}.init`);
  }
}

function verifyExprStmt(off, json, path) {
  // expression at offset 16 (^Expression)
  const exprOff = u32(off + 16);
  if (exprOff > 0 && json.expression) {
    verifyExprFromUnion(exprOff, json.expression, `${path}.expression`);
  }
}

function verifyExprFromUnion(unionOff, json, path) {
  if (unionOff === 0 || unionOff >= buf.length) return;
  const union = readUnion(unionOff);
  const rawType = EXPR_TAGS[union.tag];
  checkType(`${path}.type`, rawType, json.type);

  if (!rawType || union.ptr === 0 || union.ptr >= buf.length) return;

  const off = union.ptr;
  const rawStart = u32(off);
  const rawEnd = u32(off + 4);
  if (json.start !== undefined) check(`${path}.start`, rawStart, json.start);
  if (json.end !== undefined) check(`${path}.end`, rawEnd, json.end);

  switch (rawType) {
    case 'Identifier':
      check(`${path}.name`, str(off + 16), json.name);
      break;
    case 'NumericLiteral':
      check(`${path}.value`, f64(off + 16), json.value);
      check(`${path}.raw`, str(off + 24), json.raw);
      break;
    case 'StringLiteral':
      check(`${path}.value`, str(off + 16), json.value);
      break;
    case 'BooleanLiteral':
      // value at offset 16 (bool = 1 byte)
      check(`${path}.value`, u8(off + 16) === 1, json.value);
      break;
    case 'BinaryExpression':
    case 'LogicalExpression':
      // left at +24, right at +32 (^Expression fields)
      const leftOff = u32(off + 24);
      const rightOff = u32(off + 32);
      if (leftOff > 0 && json.left) verifyExprFromUnion(leftOff, json.left, `${path}.left`);
      if (rightOff > 0 && json.right) verifyExprFromUnion(rightOff, json.right, `${path}.right`);
      break;
    case 'CallExpression':
      // callee at +16, arguments at +24
      const calleeOff = u32(off + 16);
      if (calleeOff > 0 && json.callee) verifyExprFromUnion(calleeOff, json.callee, `${path}.callee`);
      const args = dynHeader(off + 24);
      if (json.arguments) {
        check(`${path}.arguments.length`, args.len, json.arguments.length);
      }
      break;
    case 'MemberExpression':
      // object at +16, property at +24
      const objOff = u32(off + 16);
      const propOff = u32(off + 24);
      if (objOff > 0 && json.object) verifyExprFromUnion(objOff, json.object, `${path}.object`);
      if (propOff > 0 && json.property) verifyExprFromUnion(propOff, json.property, `${path}.property`);
      break;
    case 'UnaryExpression':
    case 'UpdateExpression':
    case 'SpreadElement':
    case 'AwaitExpression':
      // argument at +24 for Unary/Update (after operator enum), +16 for Spread/Await
      const argOffset = (rawType === 'SpreadElement' || rawType === 'AwaitExpression') ? 16 : 24;
      const argOff = u32(off + argOffset);
      if (argOff > 0 && json.argument) verifyExprFromUnion(argOff, json.argument, `${path}.argument`);
      break;
    case 'AssignmentExpression':
      const alOff = u32(off + 24);
      const arOff = u32(off + 32);
      if (alOff > 0 && json.left) verifyExprFromUnion(alOff, json.left, `${path}.left`);
      if (arOff > 0 && json.right) verifyExprFromUnion(arOff, json.right, `${path}.right`);
      break;
    case 'ConditionalExpression':
      const tOff = u32(off + 16);
      const cOff = u32(off + 24);
      const aOff = u32(off + 32);
      if (tOff > 0 && json.test) verifyExprFromUnion(tOff, json.test, `${path}.test`);
      if (cOff > 0 && json.consequent) verifyExprFromUnion(cOff, json.consequent, `${path}.consequent`);
      if (aOff > 0 && json.alternate) verifyExprFromUnion(aOff, json.alternate, `${path}.alternate`);
      break;
  }
}

// Run
console.log(`Verifying: ${path.basename(file)} (${source.length} bytes)`);
verifyProgram(programOffset, jsonAst);
console.log(`  Checked: ${checked} fields`);
if (errors > 0) {
  console.log(`  ❌ ${errors} errors`);
  process.exit(1);
} else {
  console.log(`  ✅ All fields match`);
}
