#+build windows

// Windows stub for the mmap path — `source_read` always falls back to
// `os.read_entire_file_from_path`.
//
// A future Windows path could use `CreateFileMapping` / `MapViewOfFile`,
// but the user-perceived savings are below human perception (~90 µs
// on a CLI run) — not worth the platform code today. See source_io.odin
// for the full rationale.

package kessel

source_try_mmap :: proc(path: string) -> (data: []u8, mapped: bool, ok: bool) {
	return nil, false, false
}

source_unmap :: proc(data: []u8) {}
