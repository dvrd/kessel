package kessel

import "core:fmt"
import mvirtual "core:mem/virtual"

cli_declarations :: proc(path: string) -> int {
	job: ParseJob
	if !parse_job_open(&job, path, {preserve_parens = true, allow_legacy_module_names = true}) {
		fmt.eprintf("error: could not read %s\n", path)
		return 1
	}
	defer parse_job_close(&job)
	parse_job_run(&job)
	scratch: mvirtual.Arena
	if mvirtual.arena_init_growing(&scratch) != nil { fmt.eprintln("error: could not allocate declaration output"); return 1 }
	defer mvirtual.arena_destroy(&scratch)
	result := declarations_generate(&job, mvirtual.arena_allocator(&scratch))
	for e in result.errors { fmt.eprintf("%s:%d:%d %s: %s\n", path, e.start, e.end, e.code, e.message) }
	if len(result.errors) > 0 { return 1 }
	out_print(result.output)
	return 0
}
