package pbr

import "base:runtime"

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

assertion_failure_proc :: proc(prefix, message: string, loc: runtime.Source_Code_Location) -> ! {
	builder: strings.Builder
	strings.builder_init(&builder)

	when !ODIN_DISABLE_ASSERT {
		strings.write_string(&builder, loc.file_path)
		strings.write_byte(&builder, '(')
		strings.write_u64(&builder, u64(loc.line))
		if loc.column != 0 {
			strings.write_byte(&builder, ':')
			strings.write_u64(&builder, u64(loc.column))
		}
		strings.write_string(&builder, ") ")
	}

	if len(message) > 0 {
		strings.write_string(&builder, message)
		strings.write_byte(&builder, '\n')
	}

	app_message_box(strings.to_string(builder))

	runtime.trap()
}
