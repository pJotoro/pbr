package pbr

import "core:fmt"
import "core:strings"

dprint :: proc(args: ..any, sep := " ") -> string {
	str := fmt.tprint(args, sep)
	cstr := strings.clone_to_cstring(str)
	dprint_cstring(cstr)
	return str
}

dprintf :: proc(format: string, args: ..any, newline := false) -> string {
	str := fmt.tprintf(fmt=format, args=args, newline=newline)
	cstr := strings.clone_to_cstring(str)
	dprint_cstring(cstr)
	return str
}