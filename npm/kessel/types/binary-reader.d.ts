/**
 * Binary AST decoder.
 *
 * Decodes the wire-format buffer produced by `libkessel` into ESTree
 * objects. This is the second half of the FFI fast path used internally
 * by `parseSync`; expose it directly only when you need to receive AST
 * buffers via a transport other than `parseSync`'s call.
 */

import type { ParseResult } from './index';

/**
 * Decode a `libkessel` binary AST buffer.
 *
 * The buffer is typed as `Uint8Array` so the declaration doesn't drag in
 * `@types/node` for consumers. Node's `Buffer` extends `Uint8Array`, so
 * passing a `Buffer` is fine at runtime.
 *
 * @param buffer The binary AST buffer.
 * @param source The original source string. Required to materialize
 *               string literal values that live as `(offset, length)`
 *               pairs in the buffer rather than inline bytes.
 */
export function decode(buffer: Uint8Array, source: string): ParseResult;
