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
  TSTypeAssertion: 98, TSInstantiationExpression: 99,
};

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
  'TSTypeAssertion', 'TSInstantiationExpression',
];

const VAR_KINDS = ['var', 'let', 'const', 'using', 'await using'];
const PROP_KINDS = ['init', 'get', 'set'];
const CLASS_ELEM_KINDS = ['method', 'get', 'set', 'constructor', 'method']; // StaticBlock mapped to method

// Value type tags — must match BinValType in binary_emitter.odin.
// VT_NODE and VT_NULL_NODE are above the BinNodeType range (0..99)
// to avoid collisions when peeking at the first byte of a field.
const VT_NULL = 0, VT_STR = 4;
const VT_NODE = 0xFD, VT_NULL_NODE = 0xFE;

/**
 * Decode a binary AST buffer into an ESTree-compatible Program object.
 * @param {Buffer|Uint8Array} buffer - The binary buffer from kessel --binary
 * @param {string} source - Original source text (for string resolution)
 * @returns {{ program: object, errors: Array }}
 */
function decode(buffer, source) {
  const dv = new DataView(buffer.buffer || buffer, buffer.byteOffset || 0, buffer.byteLength || buffer.length);
  let off = 0;

  // Validate header (24 bytes, all little-endian u32):
  //   0  magic            0x4B455354 ('KEST')
  //   4  version          must be 2
  //   8  node_count
  //  12  string_table_off
  //  16  errors_off       (0 = no errors section, treat as count=0)
  //  20  error_count
  const magic = dv.getUint32(0, true);
  if (magic !== 0x4B455354) throw new Error('Invalid binary AST magic: 0x' + magic.toString(16));
  const version = dv.getUint32(4, true);
  if (version !== 2) throw new Error('Unsupported binary AST version: ' + version);
  const nodeCount = dv.getUint32(8, true);
  const strTableOff = dv.getUint32(12, true);
  const errorsOff = dv.getUint32(16, true);
  const errorCount = dv.getUint32(20, true);
  off = 24;

  // Build string table
  const strings = buildStringTable(dv, strTableOff, buffer, source);

  // Read node stream
  let depth = 0;
  const MAX_DEPTH = 512;
  const program = readNode();

  // Decode errors section, if present. Each error is laid out inline:
  //   u32 loc, u32 msg_len, msg_len bytes (UTF-8). No padding.
  // `start` and `end` both point at `loc` for now — the Odin parser
  // currently tracks errors as single-point locations; token-aware
  // spans are future work.
  const errors = [];
  if (errorCount > 0 && errorsOff > 0) {
    const u8 = buffer instanceof Uint8Array
      ? buffer
      : new Uint8Array(buffer.buffer, buffer.byteOffset || 0, buffer.byteLength || buffer.length);
    const decoder = new TextDecoder();
    let eoff = errorsOff;
    for (let i = 0; i < errorCount; i++) {
      const loc = dv.getUint32(eoff, true); eoff += 4;
      const msgLen = dv.getUint32(eoff, true); eoff += 4;
      const message = decoder.decode(u8.subarray(eoff, eoff + msgLen));
      eoff += msgLen;
      errors.push({ message, start: loc, end: loc });
    }
  }

  return { program, errors };

  function readU8() { if (off >= dv.byteLength) return 0; return dv.getUint8(off++); }
  function readU32() { if (off + 4 > dv.byteLength) return 0; const v = dv.getUint32(off, true); off += 4; return v; }
  function readF64() { if (off + 8 > dv.byteLength) return 0; const v = dv.getFloat64(off, true); off += 8; return v; }
  function readBool() { if (off >= dv.byteLength) return false; return dv.getUint8(off++) !== 0; }
  function readStr() { const idx = readU32(); return idx < strings.length ? strings[idx] : ''; }

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
    if (count > 100000 || off + count > strTableOff) throw new Error('readNodeArray: bogus count ' + count + ' at off ' + off);
    const arr = new Array(count);
    for (let i = 0; i < count; i++) arr[i] = readNode();
    return arr;
  }

  function readNodeOrNullArray() {
    const count = readU32();
    if (count > 100000 || off + count > strTableOff) throw new Error('readNodeOrNullArray: bogus count ' + count + ' at off ' + off);
    const arr = new Array(count);
    for (let i = 0; i < count; i++) arr[i] = readNodeOrNull();
    return arr;
  }

  function readNode() {
    if (off >= strTableOff) return null;
    if (++depth > MAX_DEPTH) throw new Error('readNode depth exceeded ' + MAX_DEPTH + ' at offset ' + off);
    // Peek at the first byte. If it's a NullNode tag (0xFE), consume
    // just that one byte and return null — the emitter writes NullNode
    // in bare-node positions for nil/unknown AST nodes.
    const peek = dv.getUint8(off);
    if (peek === VT_NULL_NODE) {
      off++;
      --depth;
      return null;
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
        break;
      case T.NullLiteral:
        node.value = null;
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
        const idTag = readU8();
        node.id = idTag === VT_STR ? { type: 'Identifier', name: readStr(), start, end } : null;
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
        const idTag = readU8();
        node.id = idTag === 4 ? { type: 'Identifier', name: readStr(), start, end } : null;
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
      case T.PropertyDefinition:
        node.computed = readBool();
        node.static = readBool();
        node.key = readNodeOrNull();
        node.value = readNodeOrNull();
        break;
      case T.StaticBlock:
        node.body = readNodeOrNull(); // wrapping expression (FunctionExpression)
        break;
      case T.MemberExpression:
        node.computed = readBool();
        node.optional = readBool();
        node.object = readNode();
        node.property = readNode();
        break;
      case T.CallExpression:
        node.optional = readBool();
        node.callee = readNode();
        node.arguments = readNodeArray();
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
      case T.BinaryExpression:
      case T.LogicalExpression:
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
        node.meta = { type: 'Identifier', name: readStr(), start, end };
        node.property = { type: 'Identifier', name: readStr(), start, end };
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
        const labelTag = readU8();
        node.label = labelTag === VT_STR ? { type: 'Identifier', name: readStr(), start, end } : null;
        break;
      }
      case T.LabeledStatement:
        node.label = { type: 'Identifier', name: readStr(), start, end };
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
        node.specifiers = readNodeArray();
        node.source = { type: 'Literal', value: readStr(), start, end };
        break;
      case T.ImportSpecifier:
        node.imported = { type: 'Identifier', name: readStr(), start, end };
        node.local = { type: 'Identifier', name: readStr(), start, end };
        break;
      case T.ImportDefaultSpecifier:
      case T.ImportNamespaceSpecifier:
        node.local = { type: 'Identifier', name: readStr(), start, end };
        break;
      case T.ExportNamedDeclaration:
        node.declaration = readNodeOrNull();
        node.specifiers = readNodeArray();
        { const srcTag = readU8();
          node.source = srcTag === VT_STR ? { type: 'Literal', value: readStr(), start, end } : null; }
        break;
      case T.ExportDefaultDeclaration:
        node.declaration = readNode();
        break;
      case T.ExportAllDeclaration:
        node.source = { type: 'Literal', value: readStr(), start, end };
        { const expTag = readU8();
          node.exported = expTag === VT_STR ? { type: 'Identifier', name: readStr(), start, end } : null; }
        break;
      case T.ExportSpecifier:
        node.local = { type: 'Identifier', name: readStr(), start, end };
        node.exported = { type: 'Identifier', name: readStr(), start, end };
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
        params[i] = { type: 'AssignmentPattern', start: pat.start, end: def.end, left: pat, right: def };
      } else {
        params[i] = pat;
      }
    }
    return params;
  }
}

function buildStringTable(dv, tableOff, buffer, source) {
  const buf = buffer.buffer ? new Uint8Array(buffer.buffer, buffer.byteOffset, buffer.byteLength) : buffer;
  const strings = [];
  let off = tableOff;

  while (off + 8 <= buf.length) {
    const rawOff = dv.getUint32(off, true);
    const len = dv.getUint32(off + 4, true);
    off += 8;

    if (len === 0) {
      strings.push('');
      continue;
    }

    const isCooked = (rawOff & 0x80000000) !== 0;
    const cleanOff = rawOff & 0x7FFFFFFF;

    if (isCooked) {
      // Read from buffer
      strings.push(new TextDecoder().decode(buf.slice(cleanOff, cleanOff + len)));
    } else {
      // Slice from source
      strings.push(source.slice(cleanOff, cleanOff + len));
    }
  }
  return strings;
}

module.exports = { decode };
