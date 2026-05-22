/**
 * visitor.js — Simple ESTree tree visitor for kessel-parser output.
 *
 * Provides `walk(node, visitor)` that traverses the AST produced by
 * parseSync and calls visitor hooks for each node type.
 *
 * Usage:
 *   const { parseSync } = require('kessel-parser');
 *   const { walk } = require('kessel-parser/visitor');
 *
 *   const { program } = parseSync('test.js', source);
 *   walk(program, {
 *     FunctionDeclaration(node) { console.log('fn:', node.id?.name); },
 *     'CallExpression:exit'(node) { ... },  // post-order
 *   });
 */

'use strict';

// ESTree child-field map: maps each node type to the names of fields that
// contain child nodes. Only structural children (not decorators, comments,
// type annotations) are listed — visitors that need those can access them
// directly from the node object.
const CHILDREN = {
  // Programs
  Program: ['body'],

  // Statements
  BlockStatement: ['body'],
  ExpressionStatement: ['expression'],
  IfStatement: ['test', 'consequent', 'alternate'],
  ReturnStatement: ['argument'],
  ThrowStatement: ['argument'],
  WhileStatement: ['test', 'body'],
  DoWhileStatement: ['body', 'test'],
  ForStatement: ['init', 'test', 'update', 'body'],
  ForInStatement: ['left', 'right', 'body'],
  ForOfStatement: ['left', 'right', 'body'],
  SwitchStatement: ['discriminant', 'cases'],
  SwitchCase: ['test', 'consequent'],
  TryStatement: ['block', 'handler', 'finalizer'],
  CatchClause: ['param', 'body'],
  LabeledStatement: ['label', 'body'],
  WithStatement: ['object', 'body'],
  BreakStatement: ['label'],
  ContinueStatement: ['label'],
  DebuggerStatement: [],
  EmptyStatement: [],

  // Declarations
  FunctionDeclaration: ['id', 'params', 'body'],
  VariableDeclaration: ['declarations'],
  VariableDeclarator: ['id', 'init'],
  ClassDeclaration: ['id', 'superClass', 'body'],
  ClassBody: ['body'],
  MethodDefinition: ['key', 'value'],
  PropertyDefinition: ['key', 'value'],
  StaticBlock: ['body'],

  // Expressions
  Identifier: [],
  Literal: [],
  TemplateLiteral: ['quasis', 'expressions'],
  TaggedTemplateExpression: ['tag', 'quasi'],
  ArrayExpression: ['elements'],
  ObjectExpression: ['properties'],
  Property: ['key', 'value'],
  SpreadElement: ['argument'],
  FunctionExpression: ['id', 'params', 'body'],
  ArrowFunctionExpression: ['params', 'body'],
  ClassExpression: ['id', 'superClass', 'body'],
  UnaryExpression: ['argument'],
  BinaryExpression: ['left', 'right'],
  LogicalExpression: ['left', 'right'],
  AssignmentExpression: ['left', 'right'],
  UpdateExpression: ['argument'],
  MemberExpression: ['object', 'property'],
  ChainExpression: ['expression'],
  CallExpression: ['callee', 'arguments'],
  NewExpression: ['callee', 'arguments'],
  ConditionalExpression: ['test', 'consequent', 'alternate'],
  SequenceExpression: ['expressions'],
  YieldExpression: ['argument'],
  AwaitExpression: ['argument'],
  ImportExpression: ['source'],
  MetaProperty: [],
  AssignmentPattern: ['left', 'right'],
  ArrayPattern: ['elements'],
  ObjectPattern: ['properties'],
  RestElement: ['argument'],
  ParenthesizedExpression: ['expression'],

  // JSX
  JSXElement: ['openingElement', 'children', 'closingElement'],
  JSXFragment: ['openingFragment', 'children', 'closingFragment'],
  JSXOpeningElement: ['name', 'attributes'],
  JSXClosingElement: ['name'],
  JSXAttribute: ['name', 'value'],
  JSXSpreadAttribute: ['argument'],
  JSXExpressionContainer: ['expression'],
  JSXSpreadChild: ['expression'],
  JSXText: [],
  JSXIdentifier: [],
  JSXMemberExpression: ['object', 'property'],
  JSXNamespacedName: [],
  JSXEmptyExpression: [],

  // Modules
  ImportDeclaration: ['specifiers', 'source'],
  ImportSpecifier: ['imported', 'local'],
  ImportDefaultSpecifier: ['local'],
  ImportNamespaceSpecifier: ['local'],
  ExportNamedDeclaration: ['declaration', 'specifiers', 'source'],
  ExportDefaultDeclaration: ['declaration'],
  ExportAllDeclaration: ['exported', 'source'],
  ExportSpecifier: ['exported', 'local'],

  // TS types (structural only — not emitting into visitor by default)
  TSTypeAnnotation: [],
  TSTypeParameterDeclaration: [],
  TSTypeParameterInstantiation: [],
  TSAsExpression: ['expression'],
  TSSatisfiesExpression: ['expression'],
  TSNonNullExpression: ['expression'],
  TSTypeAssertion: ['expression'],
  TSParameterProperty: ['parameter'],
};

/**
 * walk — depth-first pre/post-order ESTree visitor.
 *
 * @param {object|null} node    Root AST node.
 * @param {object} visitor      Map of nodeType → enter fn, 'nodeType:exit' → exit fn.
 *                              Any key not matching a known type is silently ignored.
 */
function walk(node, visitor) {
  if (!node || typeof node !== 'object') return;
  if (Array.isArray(node)) {
    for (const child of node) walk(child, visitor);
    return;
  }
  const type = node.type;
  if (!type) return;

  // Enter hook
  const enter = visitor[type];
  if (typeof enter === 'function') enter(node);

  // Recurse into children
  const childFields = CHILDREN[type];
  if (childFields) {
    for (const field of childFields) {
      const child = node[field];
      if (child == null) continue;
      if (Array.isArray(child)) {
        for (const c of child) if (c) walk(c, visitor);
      } else {
        walk(child, visitor);
      }
    }
  } else {
    // Unknown type — walk all own-property object values as a best-effort.
    for (const key of Object.keys(node)) {
      if (key === 'type' || key === 'start' || key === 'end' || key === 'loc' ||
          key === 'range') continue;
      const val = node[key];
      if (val && typeof val === 'object') walk(val, visitor);
    }
  }

  // Exit hook
  const exit = visitor[`${type}:exit`];
  if (typeof exit === 'function') exit(node);
}

/**
 * findAll — collect all nodes of given type(s) via a full walk.
 *
 * @param {object} root    AST root or any node.
 * @param {...string} types Node type names to collect.
 * @returns {object[]}      All matching nodes in pre-order traversal order.
 */
function findAll(root, ...types) {
  const set = new Set(types);
  const results = [];
  walk(root, Object.fromEntries([...set].map((t) => [t, (n) => results.push(n)])));
  return results;
}

module.exports = { walk, findAll };
