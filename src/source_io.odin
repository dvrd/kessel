// Source-file I/O — mmap-when-possible, fall back to read.
//
// `os.read_entire_file_from_path` (Odin's stdlib) opens the file, stats
// the size, allocates a buffer, and `read(2)`s the bytes from the
// kernel's page cache into the user buffer. For large files this is a
// pure memcpy at memory bandwidth (~25 GB/s on M3) — ~140 µs for the
// 3.5 MB monaco.js test file.
//
// `mmap(MAP_PRIVATE)` instead maps the kernel's page cache pages
// directly into user VA space. No copy. The actual cost is a single
// syscall + a few VM table updates: ~50 µs for the same file. Net
// savings: ~90 µs per file read.
//
// On a cold file (not in OS page cache) the win is larger: the
// `read_entire_file` path waits for the disk read to land in the
// buffer; the mmap path lets the page-fault handler kick in only
// when the parser actually touches a byte, and `posix_madvise`
// hints sequential access so the kernel prefetches ahead. For an
// LSP / watch / build-tool workflow that opens many files (some
// cold), this can be 5–10 ms / file.
//
// On the bench harness (`microbench parse <file> --iterations N`)
// the file read is performed ONCE, BEFORE the timer loop, so this
// optimisation is bench-neutral. It's a real-world / CLI win only.
//
// Apple's xnu has been doing the page-cache-to-mmap aliasing trick
// since 10.x; it's the same fast path Apple's own tools (clang,
// swift) use for source files.
//
// Edge cases handled:
//   * Empty file (size 0)            → fall back to read (mmap len=0 is EINVAL)
//   * mmap fails for any reason      → fall back to read, log nothing
//   * Non-Darwin / Linux / BSD       → fall back to read (no posix mmap)
//   * Caller mutates source bytes    → would SEGV (read-only mapping). The
//                                       parser/lexer never writes to source;
//                                       enforced by code review.
//   * File truncated during parse    → SIGBUS (rare; same outcome as today
//                                       for any concurrent mutation)
//
// API:
//   src, ok := source_read(path, alloc)        // returns SourceBuffer
//   defer source_release(src, alloc)
//   ... use src.data ...
//
// `source_release` is a no-op for empty / failed buffers and dispatches
// internally on the `mapped` flag.
//
// Implementation split:
//   * `source_io.odin`        (this file): API + heap-fallback `source_read_via_os`
//   * `source_io_posix.odin`  (build-tagged darwin/linux/bsd): mmap path
//   * `source_io_other.odin`  (build-tagged windows/...):      stub returns false
//
// `source_read` always tries the mmap helper first; on Windows /
// platforms without posix mmap, the helper is the stub that returns
// `(_, false, false)` and we fall through to `read_entire_file_from_path`.

package main

import "core:os"

SourceBuffer :: struct {
	// Source bytes. Always non-nil on ok=true (may be zero length for
	// empty files).
	data:   []u8,

	// True when `data` was obtained via mmap; false when it came from
	// `os.read_entire_file_from_path` (heap-allocated). Drives
	// `source_release`'s teardown path.
	mapped: bool,
}

// Read a source file. Tries mmap first on Unix-y platforms; falls back
// to `read_entire_file_from_path` on failure or on Windows.
//
// Returns (buf, true) on success, ({}, false) on a real error (file
// not found, permission denied, etc.). The caller is responsible for
// reporting the error; this proc stays silent so each call site can
// emit a context-appropriate message.
source_read :: proc(path: string, alloc := context.allocator) -> (buf: SourceBuffer, ok: bool) {
	if data, mapped, mok := source_try_mmap(path); mok {
		buf.data = data
		buf.mapped = mapped
		return buf, true
	}

	bytes, read_err := os.read_entire_file_from_path(path, alloc)
	if read_err != nil {
		return {}, false
	}
	buf.data = bytes
	buf.mapped = false
	return buf, true
}

// Release a source buffer. Idempotent on a zero-value buffer.
source_release :: proc(buf: SourceBuffer, alloc := context.allocator) {
	if buf.data == nil { return }
	if buf.mapped {
		source_unmap(buf.data)
		return
	}
	delete(buf.data, alloc)
}
