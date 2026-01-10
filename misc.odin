package pbr

import "base:runtime"
import "core:debug/trace"

import "core:fmt"
import "core:strings"

when STACK_TRACE {
    global_trace_ctx: trace.Context

    debug_trace_assertion_failure_proc :: proc(prefix, message: string, loc := #caller_location) -> ! {
        runtime.print_caller_location(loc)
        runtime.print_string(" ")
        runtime.print_string(prefix)
        if len(message) > 0 {
            runtime.print_string(": ")
            runtime.print_string(message)
        }
        runtime.print_byte('\n')

        ctx := &global_trace_ctx
        if !trace.in_resolve(ctx) {
            buf: [64]trace.Frame
            runtime.print_string("Debug Trace:\n")
            frames := trace.frames(ctx, 1, buf[:])
            for f, i in frames {
                fl := trace.resolve(ctx, f, context.temp_allocator)
                if fl.loc.file_path == "" && fl.loc.line == 0 {
                    continue
                }
                runtime.print_caller_location(fl.loc)
                runtime.print_string(" - frame ")
                runtime.print_int(i)
                runtime.print_byte('\n')
            }
        }
        runtime.trap()
    }

    debug_trace_init :: proc() {
    	trace.init(&global_trace_ctx)
        context.assertion_failure_proc = debug_trace_assertion_failure_proc
    }
} else {
	debug_trace_init :: proc() {}
}

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