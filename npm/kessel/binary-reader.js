/**
 * Binary AST reader — decodes kessel's compact binary format into ESTree objects.
 *
 * Format: [Header 16B] [Node stream ...] [String table ...]
 * Each node: [type_id: u8] [start: u32] [end: u32] [fields...]
 *
 * The node stream is DFS pre-order. Children are written immediately after
 * their parent in the byte stream. The reader follows the same DFS order,
 * using a state machine per node type to know how many children to read.
 */

'use strict';

// Node type IDs — must match BinNodeType in binary_emitter.odin exactly.
const T = {
  Program: 0, Identifier: 1, PrivateIdentifier: 2,
  NumericLiteral: 3, StringLiteral: 4, BooleanLiteral: 5,
  NullLiteral: 6, BigIntLiteral: 7, RegExpLiteral: 8,
  TemplateLiteral: 9, TemplateElement: 10, TaggedTemplateExpression: 11,
  ThisExpression: 12, Super: 13, ArrayExpression: 14,
  ObjectExpression: 15, Property: 16, SpreadElement: 17,
  FunctionExpression: 18, ArrowFunctionExpression: 19,
  ClassExpression: 20, ClassBody: 21, MethodDefinition: 22,
  PropertyDefinition: 23, StaticBlock: 24, MemberExpression: 25,
  CallExpression: 26, NewExpression: 27, ConditionalExpression: 28,
  UpdateExpression: 29, UnaryExpression: 30, BinaryExpression: 31,
  LogicalExpression: 32, AssignmentExpression: 33, SequenceExpression: 34,
  YieldExpression: 35, AwaitExpression: 36, ImportExpression: 37,
  MetaProperty: 38, ChainExpression: 39, ParenthesizedExpression: 40,
  ExpressionStatement: 41, Directive: 42, BlockStatement: 43,
  EmptyStatement: 44, DebuggerStatement: 45, ReturnStatement: 46,
  BreakStatement: 47, ContinueStatement: 48, LabeledStatement: 49,
  IfStatement: 50, SwitchStatement: 51, SwitchCase: 52,
  WhileStatement: 53, DoWhileStatement: 54, ForStatement: 55,
  ForInStatement: 56, ForOfStatement: 57, WithStatement: 58,
  ThrowStatement: 59, TryStatement: 60, CatchClause: 61,
  FunctionDeclaration: 62, VariableDeclaration: 63, VariableDeclarator: 64,
  ClassDeclaration: 65, ObjectPattern: 66, ArrayPattern: 67,
  AssignmentPattern: 68, RestElement: 69,
  ImportDeclaration: 70, ImportSpecifier: 71, ImportDefaultSpecifier: 72,
  ImportNamespaceSpecifier: 73, ExportNamedDeclaration: 74,
  ExportDefaultDeclaration: 75, ExportAllDeclaration: 76, ExportSpecifier: 77,
  JSXElement: 78, JSXFragment: 79, JSXOpeningElement: 80,
  JSXClosingElement: 81, JSXOpeningFragment: 82, JSXClosingFragment: 83,
  JSXAttribute: 84, JSXSpreadAttribute: 85, JSXExpressionContainer: 86,
  JSXEmptyExpression: 87, JSXText: 88, JSXIdentifier: 89,
  JSXMemberExpression: 90, JSXNamespacedName: 91, JSXSpreadChild: 92,
  TSTypeAnnotation: 93, TSTypeReference: 94, TSAsExpression: 95,
  TSSatisfiesExpression: 96, TSNonNullExpression: 97,
  TSTypeAssertion: 98, TSInstantiationExpression: 99, TypedRecord: 100, TypedPrefix: 101,
  Hashbang: 102,
};

const RESERVED_FIELDS = new Set(['type', 'start', 'end', '__proto__', 'prototype', 'constructor']);

const TYPE_NAMES = [
  'Program', 'Identifier', 'PrivateIdentifier',
  'Literal', 'Literal', 'Literal', 'Literal', 'Literal', 'Literal',
  'TemplateLiteral', 'TemplateElement', 'TaggedTemplateExpression',
  'ThisExpression', 'Super', 'ArrayExpression',
  'ObjectExpression', 'Property', 'SpreadElement',
  'FunctionExpression', 'ArrowFunctionExpression',
  'ClassExpression', 'ClassBody', 'MethodDefinition',
  'PropertyDefinition', 'StaticBlock', 'MemberExpression',
  'CallExpression', 'NewExpression', 'ConditionalExpression',
  'UpdateExpression', 'UnaryExpression', 'BinaryExpression',
  'LogicalExpression', 'AssignmentExpression', 'SequenceExpression',
  'YieldExpression', 'AwaitExpression', 'ImportExpression',
  'MetaProperty', 'ChainExpression', 'ParenthesizedExpression',
  'ExpressionStatement', 'Directive', 'BlockStatement',
  'EmptyStatement', 'DebuggerStatement', 'ReturnStatement',
  'BreakStatement', 'ContinueStatement', 'LabeledStatement',
  'IfStatement', 'SwitchStatement', 'SwitchCase',
  'WhileStatement', 'DoWhileStatement', 'ForStatement',
  'ForInStatement', 'ForOfStatement', 'WithStatement',
  'ThrowStatement', 'TryStatement', 'CatchClause',
  'FunctionDeclaration', 'VariableDeclaration', 'VariableDeclarator',
  'ClassDeclaration', 'ObjectPattern', 'ArrayPattern',
  'AssignmentPattern', 'RestElement',
  'ImportDeclaration', 'ImportSpecifier', 'ImportDefaultSpecifier',
  'ImportNamespaceSpecifier', 'ExportNamedDeclaration',
  'ExportDefaultDeclaration', 'ExportAllDeclaration', 'ExportSpecifier',
  'JSXElement', 'JSXFragment', 'JSXOpeningElement',
  'JSXClosingElement', 'JSXOpeningFragment', 'JSXClosingFragment',
  'JSXAttribute', 'JSXSpreadAttribute', 'JSXExpressionContainer',
  'JSXEmptyExpression', 'JSXText', 'JSXIdentifier',
  'JSXMemberExpression', 'JSXNamespacedName', 'JSXSpreadChild',
  'TSTypeAnnotation', 'TSTypeReference', 'TSAsExpression',
  'TSSatisfiesExpression', 'TSNonNullExpression',
  'TSTypeAssertion', 'TSInstantiationExpression', 'TypedRecord',
];
// 101 (TypedPrefix) is a prefix byte, never a node type: it stays a hole.
TYPE_NAMES[T.Hashbang] = 'Hashbang';

const VAR_KINDS = ['var', 'let', 'const', 'using', 'await using'];
const PROP_KINDS = ['init', 'get', 'set'];
const CLASS_ELEM_KINDS = ['method', 'get', 'set', 'constructor', 'method']; // StaticBlock mapped to method
const RESOURCE_BUDGET = Object.freeze({
  // The parser's default nesting limit (ParseConfig.max_depth).
  sourceDepth: 512,
  // Node levels allowed per level of source nesting. One source level can
  // open several nodes: a method in a class body is ClassDeclaration,
  // ClassBody, MethodDefinition, FunctionExpression and BlockStatement, the
  // deepest ratio in the grammar. A budget of 512 node levels therefore
  // refused programs the parser had accepted.
  astLevelsPerSourceLevel: 6,
  // Levels that do not scale with nesting: Program, an export wrapper, and
  // the declaration, statement and expression nodes around the innermost leaf.
  astLevelsSpare: 32,
  binaryNodeArrayCount: 100000,
});

// Value type tags — must match BinValType in binary_emitter.odin.
// VT_NODE and VT_NULL_NODE are above the BinNodeType range (0..99)
// to avoid collisions when peeking at the first byte of a field.
const VT_STR = 4;
const VT_NODE = 0xFD, VT_NULL_NODE = 0xFE;

/**
 * Decode a binary AST buffer into an ESTree-compatible Program object.
 * @param {Buffer|Uint8Array} buffer - The binary buffer from kessel --binary
 * @param {string} source - Original source text (for string resolution)
 * @param {Uint8Array} [sourceBytes] - The UTF-8 bytes of `source`
 * @param {{ maxDepth?: number }} [limits] - The nesting limit the source was
 *   parsed with, when it was not the default; it sizes the decoder's budget.
 * @returns {{ program: object, errors: Array }}
 */
function decode(buffer, source, sourceBytes = new TextEncoder().encode(source), limits = {}) {
  const sourceDepth = limits.maxDepth || RESOURCE_BUDGET.sourceDepth;
  if (!Number.isInteger(sourceDepth) || sourceDepth < 1) throw new RangeError('Invalid maxDepth');
  const astDepth = sourceDepth * RESOURCE_BUDGET.astLevelsPerSourceLevel +
    RESOURCE_BUDGET.astLevelsSpare;
  const dv = new DataView(buffer.buffer || buffer, buffer.byteOffset || 0, buffer.byteLength || buffer.length);
  let off = 0;

  // Validate header (24 bytes, all little-endian u32):
  //   0  magic            0x4B455354 ('KEST')
  //   4  version          3 through 9
  //   8  node_count
  //  12  string_table_off
  //  16  errors_off       (0 = no errors section, treat as count=0)
  //  20  error_count
  const magic = dv.getUint32(0, true);
  if (magic !== 0x4B455354) throw new Error('Invalid binary AST magic: 0x' + magic.toString(16));
  const version = dv.getUint32(4, true);
  if (version < 3 || version > 9) throw new Error('Unsupported binary AST version: ' + version);
  const nodeCount = dv.getUint32(8, true);
  const strTableOff = dv.getUint32(12, true);
  const errorsOff = dv.getUint32(16, true);
  const errorCount = dv.getUint32(20, true);
  // Version 7 inferred the output shape from the presence of typed records.
  const tsShape = version === 7 || (version >= 8 && dv.getUint8(strTableOff - 1) === 1);
  off = 24;

  // Build string table
  const strings = buildStringTable(dv, strTableOff, source, sourceBytes);

  // Read node stream. Nodes outside chains are read recursively, so a tree
  // within the depth budget can still be deeper than the JavaScript stack
  // that is left when the caller is itself deeply nested or the nesting
  // limit was raised. The engine reports that as a RangeError, which is
  // caught here and restated: the process is never at risk.
  let depth = 0;
  let program;
  try {
    program = readNode();
  } catch (error) {
    if (!(error instanceof RangeError) || depth === 0) throw error;
    const failure = new RangeError('The AST is nested too deeply to decode on the remaining ' +
      'JavaScript stack (' + depth + ' node levels were open). Lower maxDepth or run Node ' +
      'with a larger --stack-size.');
    failure.code = 'AST_Too_Deep';
    throw failure;
  }

  // Decode errors section, if present. Layout depends on `version`:
  //   v3: u32 start, u32 end, u32 msg_len, msg_len bytes (UTF-8). 12B fixed.
  //   v4 through v6: u32 start, u32 end, u16 code, u8 severity, u8 _pad, u32 msg_len,
  //       msg_len bytes (UTF-8). 16B fixed.
  // `code` of 0 means 'no stable code' (legacy / un-migrated site).
  // Severity: 0 = 'error', 1 = 'warning'.
  const errors = [];
  if (errorCount > 0 && errorsOff > 0) {
    const u8 = buffer instanceof Uint8Array
      ? buffer
      : new Uint8Array(buffer.buffer, buffer.byteOffset || 0, buffer.byteLength || buffer.length);
    const decoder = new TextDecoder();
    let eoff = errorsOff;
    for (let i = 0; i < errorCount; i++) {
      const start = dv.getUint32(eoff, true); eoff += 4;
      const end   = dv.getUint32(eoff, true); eoff += 4;
      let code = 0;
      let severity = 'error';
      if (version >= 4) {
        const codeNum = dv.getUint16(eoff, true); eoff += 2;
        const sevNum  = dv.getUint8(eoff);        eoff += 1;
        eoff += 1; // _pad
        code = codeNum;
        severity = sevNum === 1 ? 'warning' : 'error';
      }
      const msgLen = dv.getUint32(eoff, true); eoff += 4;
      const message = decoder.decode(u8.subarray(eoff, eoff + msgLen));
      eoff += msgLen;
      const entry = { message, start, end };
      if (code !== 0) {
        entry.code = 'K' + String(code).padStart(4, '0');
        entry.severity = severity;
      }
      errors.push(entry);
    }
  }

  return { program, errors };

  function readU8() { if (off >= dv.byteLength) return 0; return dv.getUint8(off++); }
  function readU32() { if (off + 4 > dv.byteLength) return 0; const v = dv.getUint32(off, true); off += 4; return v; }
  function readF64() { if (off + 8 > dv.byteLength) return 0; const v = dv.getFloat64(off, true); off += 8; return v; }
  function readBool() { if (off >= dv.byteLength) return false; return dv.getUint8(off++) !== 0; }
  function readStr() { const idx = readU32(); return idx < strings.length ? strings[idx] : ''; }

  // Older streams stored these children as string indexes without individual
  // spans. Preserve the historic shape when reading an existing buffer.
  function readChild(legacyType, start, end, optional = false) {
    if (optional && readU8() !== (version >= 6 ? VT_NODE : VT_STR)) return null;
    if (version >= 6) return readNode();
    if (legacyType === 'Literal') return { type: 'Literal', value: readStr(), start, end };
    return { type: 'Identifier', name: readStr(), start, end };
  }

  function readNodeOrNull() {
    if (off >= strTableOff) return null;
    const tag = dv.getUint8(off);
    if (tag === VT_NULL_NODE) { off++; return null; }
    if (tag === VT_NODE) { off++; return readNode(); }
    // No tag prefix — direct node (some paths emit nodes without a tag)
    return readNode();
  }

  function readNodeHeader() {
    const typeId = readU8();
    const start = readU32();
    const end = readU32();
    return { typeId, start, end };
  }

  function readNodeArray() {
    const count = readU32();
    if (count > RESOURCE_BUDGET.binaryNodeArrayCount || off + count > strTableOff) throw new Error('readNodeArray: bogus count ' + count + ' at off ' + off);
    const arr = new Array(count);
    for (let i = 0; i < count; i++) arr[i] = readNode();
    return arr;
  }

  function readNodeOrNullArray() {
    const count = readU32();
    if (count > RESOURCE_BUDGET.binaryNodeArrayCount || off + count > strTableOff) throw new Error('readNodeOrNullArray: bogus count ' + count + ' at off ' + off);
    const arr = new Array(count);
    for (let i = 0; i < count; i++) arr[i] = readNodeOrNull();
    return arr;
  }

  // Version 7 adds named ESTree fields for native TypeScript nodes.
  function readRecordFields(node) {
    const limit = errorsOff || strTableOff;
    for (let count = 0; count < 64 && off < limit; count++) {
      const kind = readU8();
      if (kind === 0) return;
      const key = readStr();
      if (!key || RESERVED_FIELDS.has(key)) {
        throw new Error('Invalid binary AST field at ' + off);
      }
      switch (kind) {
        case 1: node[key] = readNode(); break;
        case 2: node[key] = readNodeArray(); break;
        case 3: node[key] = readStr(); break;
        case 4: node[key] = readU8() !== 0; break;
        case 5: node[key] = null; break;
        default: throw new Error('Invalid binary AST field kind ' + kind);
      }
    }
    throw new Error('Unterminated binary AST fields at ' + off);
  }

  // Member, call, binary and logical chains (`a.b.c`, `a()()`, `a + b + c`,
  // `a && b && c`) are the one kind of nesting the parser does not limit: a
  // generated million-term concatenation is valid input. The stream stores
  // a chain outermost-first, so it is decoded with a loop and an explicit
  // list of open links instead of one readNode call per link, which would
  // exhaust both the depth budget and the JavaScript stack. Field order on
  // each node matches what the recursive decoder produced.
  function isChainType(typeId) {
    return typeId === T.MemberExpression || typeId === T.CallExpression ||
      typeId === T.BinaryExpression || typeId === T.LogicalExpression;
  }

  function readChainInto(top, topTypeId) {
    const links = [];
    const linkTypes = [];
    let node = top;
    let typeId = topTypeId;
    let innermost = null;
    for (;;) {
      if (typeId === T.MemberExpression) {
        node.computed = readBool();
        node.optional = readBool();
      } else if (typeId === T.CallExpression) {
        node.optional = readBool();
      } else {
        node.operator = readStr();
      }
      links.push(node);
      linkTypes.push(typeId);
      // The next link follows directly when the chain operand is a bare
      // chain node; a null tag, a typed prefix or any other node ends it.
      if (off < strTableOff && isChainType(dv.getUint8(off))) {
        const header = readNodeHeader();
        typeId = header.typeId;
        node = { type: TYPE_NAMES[typeId], start: header.start, end: header.end };
        continue;
      }
      innermost = readNode();
      break;
    }
    let operand = innermost;
    for (let i = links.length - 1; i >= 0; i--) {
      const link = links[i];
      const linkType = linkTypes[i];
      if (linkType === T.MemberExpression) {
        link.object = operand;
        link.property = readNode();
      } else if (linkType === T.CallExpression) {
        link.callee = operand;
        link.arguments = readNodeArray();
      } else {
        link.left = operand;
        link.right = readNode();
      }
      operand = link;
    }
  }

  function readNode() {
    if (off >= strTableOff) return null;
    if (++depth > astDepth) {
      throw new Error('readNode depth exceeded ' + astDepth + ' at offset ' + off);
    }
    // Peek at the first byte. If it's a NullNode tag (0xFE), consume
    // just that one byte and return null — the emitter writes NullNode
    // in bare-node positions for nil/unknown AST nodes.
    const peek = dv.getUint8(off);
    if (peek === VT_NULL_NODE) {
      off++;
      --depth;
      return null;
    }
    let fields;
    if (peek === T.TypedPrefix && version >= 7) {
      off++;
      fields = {};
      readRecordFields(fields);
    }
    const { typeId, start, end } = readNodeHeader();
    const type = TYPE_NAMES[typeId];
    if (type === undefined) {
      // Unknown node type — can't parse fields. Return minimal node.
      --depth;
      return { type: 'Unknown', start, end };
    }
    const node = { type, start, end };

    switch (typeId) {
      case T.Program:
        node.sourceType = readStr();
        node.body = readNodeArray();
        node.directives = readNodeArray();
        // Version 9 appends the hashbang node. Earlier versions are only
        // emitted for programs without one.
        node.hashbang = version >= 9 ? readNodeOrNull() : null;
        break;
      case T.Hashbang:
        node.value = readStr();
        break;
      case T.Identifier:
        node.name = readStr();
        break;
      case T.PrivateIdentifier:
        node.name = readStr();
        break;
      case T.NumericLiteral:
        node.value = readF64();
        node.raw = readStr();
        break;
      case T.StringLiteral:
        node.value = readStr();
        node.raw = readStr();
        break;
      case T.BooleanLiteral:
        node.value = readBool();
        if (version >= 7) node.raw = node.value ? 'true' : 'false';
        break;
      case T.NullLiteral:
        node.value = null;
        if (version >= 7) node.raw = 'null';
        break;
      case T.BigIntLiteral:
        node.value = null; // BigInt can't be JSON'd
        node.bigint = readStr();
        node.raw = readStr();
        break;
      case T.RegExpLiteral:
        node.regex = { pattern: readStr(), flags: readStr() };
        node.value = null;
        break;
      case T.TemplateLiteral:
        node.quasis = readNodeArray();
        node.expressions = readNodeArray();
        break;
      case T.TemplateElement: {
        node.tail = readBool();
        const hasCooked = readU8();
        const cooked = hasCooked ? readStr() : null;
        node.value = { raw: readStr(), cooked };
        break;
      }
      case T.TaggedTemplateExpression:
        node.tag = readNode();
        node.quasi = readNode();
        break;
      case T.ThisExpression:
      case T.Super:
      case T.EmptyStatement:
      case T.DebuggerStatement:
        break;
      case T.ArrayExpression:
        node.elements = readNodeOrNullArray();
        break;
      case T.ObjectExpression:
        node.properties = readNodeArray();
        break;
      case T.Property: {
        node.kind = PROP_KINDS[readU8()];
        node.computed = readBool();
        node.shorthand = readBool();
        node.method = readBool();
        node.key = readNodeOrNull(); // tagged: VT_NODE or VT_NULL_NODE
        node.value = readNode();
        break;
      }
      case T.SpreadElement:
        node.argument = readNode();
        break;
      case T.FunctionExpression:
      case T.FunctionDeclaration: {
        node.id = readChild('Identifier', start, end, true);
        node.async = readBool();
        node.generator = readBool();
        node.params = readFunctionParams();
        node.body = readNode();
        break;
      }
      case T.ArrowFunctionExpression:
        node.async = readBool();
        node.expression = readBool();
        node.params = readFunctionParams();
        node.body = readNodeOrNull(); // can be null in error-recovery ASTs
        break;
      case T.ClassExpression:
      case T.ClassDeclaration: {
        node.id = readChild('Identifier', start, end, true);
        node.superClass = readNodeOrNull();
        node.body = readNode(); // ClassBody
        break;
      }
      case T.ClassBody:
        node.body = readNodeArray();
        break;
      case T.MethodDefinition:
        node.kind = CLASS_ELEM_KINDS[readU8()];
        node.computed = readBool();
        node.static = readBool();
        node.key = readNodeOrNull();
        node.value = readNodeOrNull();
        break;
      case T.PropertyDefinition: {
        node.computed = readBool();
        const flags = readU8();
        node.static = version < 5 ? flags !== 0 : Boolean(flags & 1);
        if (version >= 5 && (flags & 2)) node.declare = true;
        node.key = readNodeOrNull();
        node.value = readNodeOrNull();
        break;
      }
      case T.StaticBlock:
        node.body = readNodeOrNull(); // wrapping expression (FunctionExpression)
        break;
      case T.MemberExpression:
      case T.CallExpression:
      case T.BinaryExpression:
      case T.LogicalExpression:
        readChainInto(node, typeId);
        break;
      case T.NewExpression:
        node.callee = readNode();
        node.arguments = readNodeArray();
        break;
      case T.ConditionalExpression:
        node.test = readNode();
        node.consequent = readNode();
        node.alternate = readNode();
        break;
      case T.UpdateExpression:
        node.operator = readStr();
        node.prefix = readBool();
        node.argument = readNode();
        break;
      case T.UnaryExpression:
        node.operator = readStr();
        node.prefix = readBool();
        node.argument = readNode();
        break;
      case T.AssignmentExpression:
        node.operator = readStr();
        node.left = readNode();
        node.right = readNode();
        break;
      case T.SequenceExpression:
        node.expressions = readNodeArray();
        break;
      case T.YieldExpression:
        node.delegate = readBool();
        node.argument = readNodeOrNull();
        break;
      case T.AwaitExpression:
        node.argument = readNode();
        break;
      case T.ImportExpression:
        node.source = readNode();
        break;
      case T.MetaProperty:
        node.meta = readChild('Identifier', start, end);
        node.property = readChild('Identifier', start, end);
        break;
      case T.ChainExpression:
      case T.ParenthesizedExpression:
        node.expression = readNode();
        break;
      case T.ExpressionStatement:
        node.expression = readNode();
        break;
      case T.Directive:
        node.directive = readStr();
        node.expression = readNode();
        break;
      case T.BlockStatement:
        node.body = readNodeArray();
        break;
      case T.ReturnStatement:
        node.argument = readNodeOrNull();
        break;
      case T.BreakStatement:
      case T.ContinueStatement: {
        node.label = readChild('Identifier', start, end, true);
        break;
      }
      case T.LabeledStatement:
        node.label = readChild('Identifier', start, end);
        node.body = readNode();
        break;
      case T.IfStatement:
        node.test = readNode();
        node.consequent = readNode();
        node.alternate = readNodeOrNull();
        break;
      case T.SwitchStatement:
        node.discriminant = readNode();
        node.cases = readNodeArray();
        break;
      case T.SwitchCase:
        node.test = readNodeOrNull();
        node.consequent = readNodeArray();
        break;
      case T.WhileStatement:
        node.test = readNode();
        node.body = readNode();
        break;
      case T.DoWhileStatement:
        node.test = readNode();
        node.body = readNode();
        break;
      case T.ForStatement:
        node.init = readNodeOrNull();
        node.test = readNodeOrNull();
        node.update = readNodeOrNull();
        node.body = readNode();
        break;
      case T.ForInStatement:
        node.left = readNode();
        node.right = readNode();
        node.body = readNode();
        break;
      case T.ForOfStatement:
        node.await = readBool();
        node.left = readNode();
        node.right = readNode();
        node.body = readNode();
        break;
      case T.WithStatement:
        node.object = readNode();
        node.body = readNode();
        break;
      case T.ThrowStatement:
        node.argument = readNode();
        break;
      case T.TryStatement:
        node.block = readNode();
        node.handler = readNodeOrNull();
        node.finalizer = readNodeOrNull();
        break;
      case T.CatchClause:
        node.param = readNodeOrNull();
        node.body = readNode();
        break;
      case T.VariableDeclaration:
        node.kind = VAR_KINDS[readU8()];
        node.declarations = readNodeArray();
        break;
      case T.VariableDeclarator:
        node.id = readNode();
        node.init = readNodeOrNull();
        break;
      case T.ObjectPattern:
        node.properties = readNodeArray();
        break;
      case T.ArrayPattern:
        node.elements = readNodeOrNullArray();
        break;
      case T.AssignmentPattern:
        node.left = readNode();
        node.right = readNode();
        break;
      case T.RestElement:
        node.argument = readNode();
        break;
      case T.ImportDeclaration:
        if (tsShape) node.importKind = 'value';
        node.specifiers = readNodeArray();
        node.source = readChild('Literal', start, end);
        break;
      case T.ImportSpecifier:
        if (tsShape) node.importKind = 'value';
        node.imported = readChild('Identifier', start, end);
        node.local = readChild('Identifier', start, end);
        break;
      case T.ImportDefaultSpecifier:
      case T.ImportNamespaceSpecifier:
        node.local = readChild('Identifier', start, end);
        break;
      case T.ExportNamedDeclaration:
        node.declaration = readNodeOrNull();
        node.specifiers = readNodeArray();
        node.source = readChild('Literal', start, end, true);
        if (tsShape) node.exportKind = version === 7 && node.declaration?.declare ? 'type' : 'value';
        break;
      case T.ExportDefaultDeclaration:
        node.declaration = readNode();
        if (tsShape) node.exportKind = 'value';
        break;
      case T.ExportAllDeclaration:
        if (tsShape) node.exportKind = 'value';
        node.source = readChild('Literal', start, end);
        node.exported = readChild('Identifier', start, end, true);
        break;
      case T.ExportSpecifier:
        if (tsShape) node.exportKind = 'value';
        node.local = readChild('Identifier', start, end);
        node.exported = readChild('Identifier', start, end);
        break;
      // ===================== JSX =====================
      case T.JSXElement:
        node.openingElement = readNode(); // JSXOpeningElement
        node.children = readNodeArray();
        node.closingElement = readNodeOrNull();
        break;
      case T.JSXFragment:
        node.openingFragment = readNode(); // JSXOpeningFragment
        node.children = readNodeArray();
        node.closingFragment = readNode(); // JSXClosingFragment
        break;
      case T.JSXOpeningElement:
        node.selfClosing = readBool();
        node.name = readNode(); // JSXIdentifier | JSXMemberExpression | JSXNamespacedName
        node.attributes = readNodeArray();
        break;
      case T.JSXClosingElement:
        node.name = readNode();
        break;
      case T.JSXOpeningFragment:
      case T.JSXClosingFragment:
        // No fields beyond loc.
        break;
      case T.JSXAttribute:
        node.name = readNode(); // JSXIdentifier or JSXNamespacedName
        node.value = readNodeOrNull(); // StringLiteral or JSXExpressionContainer or null
        break;
      case T.JSXSpreadAttribute:
        node.argument = readNode();
        break;
      case T.JSXExpressionContainer:
        node.expression = readNode();
        break;
      case T.JSXEmptyExpression:
        break;
      case T.JSXText:
        node.value = readStr();
        node.raw = readStr();
        break;
      case T.JSXIdentifier:
        node.name = readStr();
        break;
      case T.JSXMemberExpression:
        node.object = readNode();
        node.property = readNode();
        break;
      case T.JSXNamespacedName:
        node.namespace = readNode();
        node.name = readNode();
        break;
      case T.JSXSpreadChild:
        node.expression = readNode();
        break;
      // ===================== TypeScript =====================
      case T.TypedRecord:
        if (version < 7) throw new Error('Typed AST record requires version 7');
        node.type = readStr();
        readRecordFields(node);
        break;
      case T.TSTypeAnnotation:
      case T.TSTypeReference:
        // TS types — not decoded for JS consumers. Skip.
        break;
      case T.TSAsExpression:
      case T.TSSatisfiesExpression:
      case T.TSNonNullExpression:
      case T.TSTypeAssertion:
      case T.TSInstantiationExpression:
        node.expression = readNode();
        break;
      default:
        // Unknown node type — skip
        break;
    }
    if (fields) Object.assign(node, fields);
    --depth;
    return node;
  }

  function readFunctionParams() {
    const count = readU32();
    const params = new Array(count);
    for (let i = 0; i < count; i++) {
      const pat = readNode(); // pattern
      const defTag = readU8();
      if (defTag === VT_NODE) {
        // AssignmentPattern wrapping
        const def = readNode();
        // Older libraries could omit either side during parser recovery.
        const start = pat?.start ?? def?.start ?? 0;
        params[i] = { type: 'AssignmentPattern', start, end: def?.end ?? pat?.end ?? start, left: pat, right: def };
      } else {
        params[i] = pat;
      }
    }
    return params;
  }
}

function buildStringTable(dv, tableOff, source, sourceBytes) {
  const buf = new Uint8Array(dv.buffer, dv.byteOffset, dv.byteLength);
  // Both offsets and lengths on the wire count UTF-8 bytes. Only ASCII
  // sources can be sliced by those offsets directly as JavaScript strings.
  const ascii = sourceBytes.length === source.length;
  const decoder = new TextDecoder('utf-8', { ignoreBOM: true });
  const strings = [];
  let off = tableOff;
  let tableEnd = buf.length;

  while (off + 8 <= tableEnd) {
    const rawOff = dv.getUint32(off, true);
    const len = dv.getUint32(off + 4, true);
    off += 8;

    const isCooked = (rawOff & 0x80000000) !== 0;
    const cleanOff = rawOff & 0x7FFFFFFF;

    if (isCooked) {
      // Cooked payloads follow the entries. The first payload marks the
      // end of the table, even when that payload is an empty string.
      tableEnd = Math.min(tableEnd, cleanOff);
      strings.push(decoder.decode(buf.subarray(cleanOff, cleanOff + len)));
    } else if (ascii) {
      strings.push(source.slice(cleanOff, cleanOff + len));
    } else {
      strings.push(decoder.decode(sourceBytes.subarray(cleanOff, cleanOff + len)));
    }
  }
  return strings;
}

module.exports = { decode };
