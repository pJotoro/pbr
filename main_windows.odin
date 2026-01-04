package pbr

import vk "vendor:vulkan"
import win32 "core:sys/windows"
import "base:intrinsics"
import "base:runtime"
import "core:strings"

VULKAN_LIB_NAME :: "vulkan-1.dll"
VK_KHR_platform_surface :: "VK_KHR_win32_surface"

@(private="file")
L :: win32.L

@(private="file")
ctx: struct {
	instance: win32.HINSTANCE,
	window: win32.HWND,
	window_class: win32.WNDCLASSEXW,
	running: bool,
}

@(private="file")
get_last_error_message :: proc() -> (string, runtime.Allocator_Error) #optional_allocator_error {
    error := win32.GetLastError()
    buf: [512]u16 = ---
    win32.FormatMessageW(win32.FORMAT_MESSAGE_FROM_SYSTEM, nil, error, 0, raw_data(buf[:]), win32.DWORD(len(buf)), nil)
    res, err := win32.wstring_to_utf8_alloc(cstring16(raw_data(buf[:])), -1)
    return strings.trim_suffix(res, "\n"), err
}

@(private="file")
format_hresult :: proc(hr: win32.HRESULT) -> (string, runtime.Allocator_Error) #optional_allocator_error {
    buf: [512]u16 = ---
    win32.FormatMessageW(win32.FORMAT_MESSAGE_FROM_SYSTEM, nil, u32(hr), 0, raw_data(buf[:]), win32.DWORD(len(buf)), nil)
    res, err := win32.wstring_to_utf8_alloc(cstring16(raw_data(buf[:])), -1)
    return strings.trim_suffix(res, "\n"), err
}

app_init :: proc() -> (w, h: int, refresh_rate: int) {
	ok: bool
	w, h, refresh_rate, ok = _app_init()
	if !ok {
		error_message := get_last_error_message()
		app_panic(error_message)
	}
    ctx.running = true
	return
}

@(private="file")
_app_init :: proc() -> (w, h: int, refresh_rate: int, ok: bool) {
    if ctx.instance = win32.HINSTANCE(win32.GetModuleHandleW(nil)); ctx.instance == nil {
        return
    }

    ctx.window_class = win32.WNDCLASSEXW {
        cbSize = size_of(win32.WNDCLASSEXW),
        lpfnWndProc = event_proc,
        hInstance = win32.HANDLE(ctx.instance),
        lpszClassName = L("pbr"),
    }
    if atom := win32.RegisterClassExW(&ctx.window_class); atom == 0 {
        return
    }
    
    {
        monitor := win32.MonitorFromPoint({0, 0}, .MONITOR_DEFAULTTOPRIMARY)
        monitor_info := win32.MONITORINFO{cbSize = size_of(win32.MONITORINFO)}
        if res := win32.GetMonitorInfoW(monitor, &monitor_info); !res {
            return
        }
        w = int(monitor_info.rcMonitor.right - monitor_info.rcMonitor.left)
        h = int(monitor_info.rcMonitor.bottom - monitor_info.rcMonitor.top)
    }
    
    if ctx.window = win32.CreateWindowExW(
        dwExStyle = win32.WS_EX_TOPMOST, 
        
        lpClassName = ctx.window_class.lpszClassName, 
        lpWindowName = L("pbr"),
        
        dwStyle = win32.WS_POPUP,
        
        X = 0, 
        Y = 0,
        nWidth = i32(w), 
        nHeight = i32(h),
        
        hWndParent = nil, 
        hMenu = nil,
        hInstance = win32.HANDLE(ctx.instance), 
        
        lpParam = nil
    ); ctx.window == nil {
        return
    }

    {
        dev_mode := win32.DEVMODEW{dmSize = size_of(win32.DEVMODEW)}
        if res := win32.EnumDisplaySettingsW(nil, win32.ENUM_CURRENT_SETTINGS, &dev_mode); !res {
            return
        }
        refresh_rate = int(dev_mode.dmDisplayFrequency)
    }

    ok = true
    return
}

vulkan_create_surface :: proc(vulkan: ^Vulkan) -> (surface: vk.SurfaceKHR, res: vk.Result) {
	res = vk.CreateWin32SurfaceKHR(
        vulkan.instance,
        &vk.Win32SurfaceCreateInfoKHR{
            sType = .WIN32_SURFACE_CREATE_INFO_KHR,
            hinstance = ctx.instance,
            hwnd = ctx.window,
        }, 
        nil,
        &surface)
	return
}

app_show :: proc() {
    @static already_shown := false
    assert(!already_shown)
    already_shown = true

    win32.ShowWindow(ctx.window, win32.SW_SHOW)
}

app_update :: proc() -> bool {
	for message: win32.MSG; win32.PeekMessageW(&message, ctx.window, 0, 0, win32.PM_REMOVE); {
        win32.TranslateMessage(&message)
        win32.DispatchMessageW(&message)
    }

    return ctx.running
}

event_proc :: proc "system" (window: win32.HWND, message: win32.UINT, w_param: win32.WPARAM, l_param: win32.LPARAM) -> win32.LRESULT {
    result: win32.LRESULT
    switch message {
        case win32.WM_CLOSE, win32.WM_DESTROY, win32.WM_QUIT:
            ctx.running = false
        case win32.WM_KEYDOWN:
            key := w_param
            switch key {
                case win32.VK_ESCAPE:
                    ctx.running = false
            }
        case:
            result = win32.DefWindowProcW(window, message, w_param, l_param)
            
    }

    return result
}

app_panic :: proc(text: string, loc := #caller_location) {
    text_wstring := win32.utf8_to_wstring(text)
    win32.MessageBoxExW(ctx.window, text_wstring, nil, win32.MB_OK|win32.MB_ICONERROR|win32.MB_TOPMOST, 0)
    panic(text, loc)
}