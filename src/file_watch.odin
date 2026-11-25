package kessel

import "base:runtime"
import "core:mem"
import "core:os"
import "core:strings"
import "core:time"

// Observe paths before reading them so edits made during a run trigger the
// next run. Tracking missing paths also covers atomic saves and new configs.
FileWatch :: struct {
	paths: map[string]FileWatchStamp,
	allocator: mem.Allocator,
}

FileWatchStamp :: struct {
	inode: u128,
	device: u64,
	size: i64,
	modified, created: time.Time,
	mode: os.Permissions,
	kind: os.File_Type,
	err: os.Error,
}

file_watch_stamp :: proc(path: string) -> FileWatchStamp {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	info, err := os.stat(path, context.temp_allocator)
	if err != nil { return {err = err} }
	return {inode = info.inode, device = info.device, size = info.size,
		modified = info.modification_time, created = info.creation_time, mode = info.mode, kind = info.type}
}

file_watch_add :: proc(watch: ^FileWatch, path: string) {
	if watch == nil || path in watch.paths { return }
	watch.paths[strings.clone(path, watch.allocator)] = file_watch_stamp(path)
}

file_watch_changed :: proc(watch: ^FileWatch) -> bool {
	changed := false
	for path, stamp in watch.paths {
		current := file_watch_stamp(path)
		if current != stamp {
			watch.paths[path] = current
			changed = true
		}
	}
	return changed
}

file_watch_wait :: proc(watch: ^FileWatch) {
	assert(watch != nil)
	assert(len(watch.paths) > 0)
	// This is the idle loop of the foreground CLI. Ctrl-C ends the process.
	for {
		time.sleep(150 * time.Millisecond)
		if file_watch_changed(watch) { break }
	}
	// Coalesce a burst of saves, but keep making progress on a busy tree.
	for _ in 0..<4 {
		time.sleep(50 * time.Millisecond)
		if !file_watch_changed(watch) { break }
	}
}
