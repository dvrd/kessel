/**
 * ESTree visitor helpers.
 *
 * `walk` performs a depth-first traversal driven by a child-field map for
 * each known node type. Hooks are looked up by `node.type` and, optionally,
 * a `:exit` suffix for post-order callbacks. Unknown node types fall back
 * to a best-effort traversal of own-property object values, which keeps
 * traversal working for TypeScript- and JSX-specific node shapes even
 * though they aren't enumerated.
 */

import type { Node } from 'estree';

/**
 * Visitor callback. The argument is typed as the standard ESTree `Node`,
 * but TypeScript / JSX nodes (`TSTypeAnnotation`, `JSXElement`, …) appear
 * here too at runtime; cast or narrow via `node.type` when needed.
 */
export type VisitorFn = (node: Node) => void;

/**
 * Map of node-type strings to enter/exit hooks.
 *
 * Keys are ESTree (or TS-/JSX-augmented) type names like `'FunctionDeclaration'`.
 * Append `:exit` to register a post-order hook: `'CallExpression:exit'`.
 * Keys that don't match any node type during traversal are silently
 * ignored — typos won't throw.
 *
 * @example
 *   walk(program, {
 *     FunctionDeclaration(node) { ... },         // pre-order (enter)
 *     'CallExpression:exit'(node) { ... },       // post-order (exit)
 *   });
 */
export interface Visitor {
  [type: string]: VisitorFn | undefined;
}

/**
 * Depth-first walk of an AST.
 *
 * @param node    Root node. Passing `null` or `undefined` is a no-op.
 * @param visitor Hooks keyed by node type (with optional `:exit` suffix).
 */
export function walk(
  node: Node | null | undefined,
  visitor: Visitor
): void;

/**
 * Collect every node of the given type(s) in pre-order traversal order.
 *
 * @param root  AST root or any subtree.
 * @param types One or more node-type names (e.g. `'CallExpression'`).
 *
 * @example
 *   const calls = findAll(program, 'CallExpression', 'NewExpression');
 */
export function findAll(root: Node, ...types: string[]): Node[];
