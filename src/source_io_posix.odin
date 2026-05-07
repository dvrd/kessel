#+build darwin, linux, freebsd, netbsd, openbsd

// POSIX mmap path — see source_io.odin for the rationale.
//
// Wraps `posix.open` + `posix.fstat` + `posix.mmap` + `posix.posix_madvise`.
// Returns (nil, false, false) on any failure path so `source_read` can
// fall back to `read_entire_file_from_path`.
//
// Read-only mapping (`PROT_READ` only). The parser / lexer never writes
// to source bytes — verified by code review. Any future writer would
// SEGV; this is a feature, not a bug (it surfaces the violation
// immediately).

package kessel

import "core:sys/posix"

// Try to mmap a file. Returns (data, true, true) on success, (nil,
// false, false) on any failure (open / stat failed, empty file, mmap
// returned MAP_FAILED).
source_try_mmap :: proc(path: string) -> (data: []u8, mapped: bool, ok: bool) {
	// Need a NUL-terminated path for posix.open. Use a small stack
	// buffer for typical paths; fall back to (false, false) for
	// pathologically long ones.
	path_buf: [4096]u8
	if len(path) >= len(path_buf) {
		return nil, false, false
	}
	copy(path_buf[:], transmute([]u8)path)
	path_buf[len(path)] = 0
	cpath := cstring(raw_data(path_buf[:]))

	// O_RDONLY is the absence of any flag bit on POSIX (the bit pattern
	// for read-only-mode access is 0); pass an empty O_Flags set.
	fd := posix.open(cpath, {})
	if fd < 0 {
		return nil, false, false
	}
	defer posix.close(fd)

	st: posix.stat_t
	if posix.fstat(fd, &st) != .OK {
		return nil, false, false
	}
	size := int(st.st_size)
	if size <= 0 {
		// Empty file — mmap with len=0 is EINVAL on Darwin. Let the
		// read path produce an empty slice.
		return nil, false, false
	}

	ptr := posix.mmap(nil, uint(size), {.READ}, {.PRIVATE}, fd, 0)
	if ptr == posix.MAP_FAILED {
		return nil, false, false
	}

	// Hint sequential access. The kernel prefetcher picks this up and
	// reads ahead one ARM page (16 KB on macOS) before the parser asks
	// for the next chunk. Failure is ignored — the hint is advisory.
	_ = posix.posix_madvise(ptr, uint(size), .SEQUENTIAL)

	data = ([^]u8)(ptr)[:size]
	return data, true, true
}

source_unmap :: proc(data: []u8) {
	if len(data) == 0 || raw_data(data) == nil { return }
	_ = posix.munmap(raw_data(data), uint(len(data)))
}
