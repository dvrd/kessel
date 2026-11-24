package kessel

import "core:os"
import "core:sys/darwin"
import "core:sys/posix"

// An atomic rename gives the result a new inode. Carry over the original
// extended attributes and access-control list before it becomes visible.
lint_fix_copy_attributes :: proc(source, target: ^os.File) -> bool {
	return darwin.fcopyfile(posix.FD(os.fd(source)), posix.FD(os.fd(target)), nil, {.ACL, .XATTR}) == 0
}
