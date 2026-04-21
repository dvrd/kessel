#!/usr/bin/env node
// Verify raw transfer buffer by reading it and reconstructing the AST

const fs = require('fs');
const path = require('path');

const binPath = process.argv[2];
const sourcePath = process.argv[3];

if (!binPath || !sourcePath) {
  console.error('Usage: node verify_raw.js <file.bin> <source.js>');
  process.exit(1);
}

const bin = fs.readFileSync(binPath);
const source = fs.readFileSync(sourcePath, 'utf8');

// Read header (first 20 bytes)
const HEADER_SIZE = 20;
const magic = bin.readUInt32LE(0);
const version = bin.readUInt32LE(4);
const programOffset = bin.readUInt32LE(8);
const sourceLen = bin.readUInt32LE(12);
const totalBytes = bin.readUInt32LE(16);

console.log('=== HEADER ===');
console.log(`  magic:    0x${magic.toString(16)} (${magic === 0x4B455353 ? 'OK - KESS' : 'BAD'})`);
console.log(`  version:  ${version}`);
console.log(`  program:  offset ${programOffset}`);
console.log(`  source:   ${sourceLen} bytes`);
console.log(`  buffer:   ${totalBytes} bytes`);

if (magic !== 0x4B455353) {
  console.error('Bad magic!');
  process.exit(1);
}

// Buffer starts after header
const buf = bin.subarray(HEADER_SIZE);
const view = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);

function readU32(offset) { return view.getUint32(offset, true); }
function readU8(offset) { return view.getUint8(offset); }
function readF64(offset) { return view.getFloat64(offset, true); }

// Read rewritten string: {u32 source_offset, u32 len} at struct offset
function readString(offset) {
  const srcOff = readU32(offset);
  const len = readU32(offset + 4);
  if (len === 0) return '';
  return source.substring(srcOff, srcOff + len);
}

// Read rewritten dynamic array header: {u32 data_offset, u32 len}
function readDynHeader(offset) {
  return { dataOffset: readU32(offset), len: readU32(offset + 4) };
}

// Read a union pointer: {u32 offset (4 bytes), pad (4 bytes), u8 tag, pad (7 bytes)}
function readUnion(offset) {
  const ptrOffset = readU32(offset);
  const tag = readU8(offset + 8);
  return { offset: ptrOffset, tag };
}

// AST node type tags for Expression union (order from ast.odin)
const EXPR_TYPES = [
  'nil',
  'NullLiteral', 'BooleanLiteral', 'NumericLiteral', 'StringLiteral',
  'BigIntLiteral', 'RegExpLiteral', 'TemplateLiteral', 'TaggedTemplateExpression',
  'Identifier', 'PrivateIdentifier', 'ThisExpression', 'Super',
  'SpreadElement', 'ArrayExpression', 'ObjectExpression',
  'FunctionExpression', 'ArrowFunctionExpression', 'ClassExpression',
  'MemberExpression', 'CallExpression', 'NewExpression',
  'ConditionalExpression', 'UpdateExpression', 'UnaryExpression',
  'BinaryExpression', 'LogicalExpression', 'AssignmentExpression',
  'SequenceExpression', 'YieldExpression', 'AwaitExpression',
  'ImportExpression', 'MetaProperty',
];

const STMT_TYPES = [
  'nil',
  'ExpressionStatement', 'EmptyStatement', 'BlockStatement',
  'DebuggerStatement', 'ReturnStatement', 'BreakStatement',
  'ContinueStatement', 'LabeledStatement', 'IfStatement',
  'SwitchStatement', 'WhileStatement', 'DoWhileStatement',
  'ForStatement', 'ForInStatement', 'ForOfStatement',
  'WithStatement', 'ThrowStatement', 'TryStatement',
  'FunctionDeclaration', 'VariableDeclaration', 'ClassDeclaration',
  'ImportDeclaration', 'ExportNamedDeclaration', 'ExportDefaultDeclaration',
  'ExportAllDeclaration',
];

// Struct layout constants
const LOC_SIZE = 16;
const PROGRAM_BODY_OFFSET = 24;         // offset of body in Program
const PROGRAM_DIRECTIVES_OFFSET = 64;   // offset of directives in Program

// Read Program
console.log('\n=== PROGRAM ===');
const pOff = programOffset;
const pSpanStart = readU32(pOff + 0);
const pSpanEnd = readU32(pOff + 4);
console.log(`  span: ${pSpanStart}-${pSpanEnd}`);

const body = readDynHeader(pOff + PROGRAM_BODY_OFFSET);
console.log(`  body: ${body.len} statements at offset ${body.dataOffset}`);

const directives = readDynHeader(pOff + PROGRAM_DIRECTIVES_OFFSET);
console.log(`  directives: ${directives.len}`);

// Read each statement in body
console.log('\n=== BODY ===');
let errors = 0;
for (let i = 0; i < body.len; i++) {
  // Each slot in the body array is a ^Statement (was 8 bytes pointer, now rewritten)
  // After rewrite: the slot contains a u32 offset to the Statement union
  const slotAddr = body.dataOffset + i * 8; // original pointer size
  const stmtOffset = readU32(slotAddr);
  
  if (stmtOffset === 0) {
    console.log(`  [${i}] NULL`);
    continue;
  }
  
  // Read the Statement union at stmtOffset
  const stmt = readUnion(stmtOffset);
  const stmtType = STMT_TYPES[stmt.tag] || `UNKNOWN(${stmt.tag})`;
  
  console.log(`  [${i}] ${stmtType} at offset ${stmt.offset}`);
  
  if (stmt.offset === 0) {
    console.log(`    (null inner pointer)`);
    continue;
  }
  
  // For VariableDeclaration, read kind and declarations
  if (stmtType === 'VariableDeclaration') {
    const vOff = stmt.offset;
    const spanStart = readU32(vOff);
    const spanEnd = readU32(vOff + 4);
    // kind is at offset 16 (after Loc), it's a VariableKind enum (8 bytes in Odin)
    const kind = readU32(vOff + 16);
    const kindNames = ['var', 'let', 'const'];
    console.log(`    span: ${spanStart}-${spanEnd}, kind: ${kindNames[kind] || kind}`);
    
    // declarations at offset 24 (after Loc:16 + kind:8)
    const decls = readDynHeader(vOff + 24);
    console.log(`    declarations: ${decls.len} at offset ${decls.dataOffset}`);
  }

  // For ExpressionStatement, read the expression
  if (stmtType === 'ExpressionStatement') {
    const esOff = stmt.offset;
    // expression is at offset 16 (after Loc)
    // It's a ^Expression — after rewrite, just a u32 offset
    const exprPtrOff = readU32(esOff + 16);
    if (exprPtrOff !== 0) {
      const expr = readUnion(exprPtrOff);
      const exprType = EXPR_TYPES[expr.tag] || `UNKNOWN(${expr.tag})`;
      console.log(`    expression: ${exprType} at ${expr.offset}`);
      
      if (exprType === 'Identifier') {
        const name = readString(expr.offset + 16); // name at offset 16 in Identifier
        console.log(`      name: "${name}"`);
      }
      if (exprType === 'NumericLiteral') {
        const val = readF64(expr.offset + 16);
        const raw = readString(expr.offset + 24);
        console.log(`      value: ${val}, raw: "${raw}"`);
      }
      if (exprType === 'BinaryExpression') {
        const leftOff = readU32(expr.offset + 24);
        const rightOff = readU32(expr.offset + 32);
        console.log(`      left at ${leftOff}, right at ${rightOff}`);
        if (leftOff) {
          const left = readUnion(leftOff);
          const lt = EXPR_TYPES[left.tag] || `?${left.tag}`;
          console.log(`      left: ${lt} at ${left.offset}`);
          if (lt === 'NumericLiteral') {
            console.log(`        value: ${readF64(left.offset + 16)}, raw: "${readString(left.offset + 24)}"`);
          }
        }
        if (rightOff) {
          const right = readUnion(rightOff);
          const rt = EXPR_TYPES[right.tag] || `?${right.tag}`;
          console.log(`      right: ${rt} at ${right.offset}`);
          if (rt === 'NumericLiteral') {
            console.log(`        value: ${readF64(right.offset + 16)}, raw: "${readString(right.offset + 24)}"`);
          }
        }
      }
    }
  }
}

if (errors === 0) {
  console.log('\n✅ Buffer verification passed');
} else {
  console.log(`\n❌ ${errors} errors`);
  process.exit(1);
}
