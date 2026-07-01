module main;

import win32;

const int BYTES_PER_PIXEL = 4;

bool running = true;

BitmapInfo bitmap_info;
void* bitmap_memory;
int bitmap_width;
int bitmap_height;

fn void render_weird_gradient(int x_offset, int y_offset) {
    int width = bitmap_width;
    int height = bitmap_height;
	int pitch = width * BYTES_PER_PIXEL;
    char* row = (char*)bitmap_memory;

    for (int y = 0; y < bitmap_height; y++) {
        uint* pixel = (uint*)row;
        for (int x = 0; x < bitmap_width; x++) {
            char blue = (char)(x + x_offset);
            char green = (char)(y + y_offset);
            *pixel++ = ((green << 8) | blue);
        }
        row += pitch;
    }
}

fn void resize_dib_section(int width, int height) {
    if (bitmap_memory) {
        win32::virtual_free(bitmap_memory, 0, VirtualFreeType.MEM_RELEASE);
    }

    bitmap_width = width;
    bitmap_height = height;

    bitmap_info.bmiHeader.biSize = BitmapInfoHeader::size;
	bitmap_info.bmiHeader.biWidth = bitmap_width;
	bitmap_info.bmiHeader.biHeight = -bitmap_height;
	bitmap_info.bmiHeader.biPlanes = 1;
	bitmap_info.bmiHeader.biBitCount = 32;
	bitmap_info.bmiHeader.biCompression = (uint)BiCompression.BI_RGB;

    int bitmap_memory_size = bitmap_width * bitmap_height * BYTES_PER_PIXEL;
    bitmap_memory = win32::virtual_alloc(
        null,
        (uptr)bitmap_memory_size,
        VirtualAllocationType.MEM_RESERVE | VirtualAllocationType.MEM_COMMIT,
        PageProtectionFlags.PAGE_READWRITE,
    );
}

fn void update_window(Hdc device_context, Rect* client_rect, int x, int y, int width, int height) {
    if (!bitmap_memory) return;

    int window_width = client_rect.right - client_rect.left;
    int window_height = client_rect.bottom - client_rect.top;

    win32::stretch_di_bits(
        device_context,
        // x, y, width, height,
        // x, y, width, height,
        x, y, width, height,
        0, 0, bitmap_width, bitmap_height,
        bitmap_memory, &bitmap_info,
        DibUsage.DIB_RGB_COLORS,
        RopCode.SRCCOPY,
    );
}

fn LResult main_window_callback(
    HWnd window,
    uint message,
    WParam w_param,
    LParam l_param,
) {
    LResult result = 0;

    switch (message) {
        case win32::WM_SIZE: {
            Rect client_rect;
            win32::get_client_rect(window, &client_rect);
            int width = client_rect.right - client_rect.left;
            int height = client_rect.bottom - client_rect.top;
            resize_dib_section(width, height);
        } break;
        case win32::WM_CLOSE: case win32::WM_DESTROY: {
            running = false;
        } break;
        case win32::WM_ACTIVATEAPP: {
            win32::output_debug_string("WM_ACTIVATEAPP\n");
        } break;
        case win32::WM_ERASEBKGND: {
            result = 1;
        } break; 
        case win32::WM_PAINT: {
            PaintStruct paint;

            Hdc hdc = win32::begin_paint(window, &paint);
            defer win32::end_paint(window, &paint);
        } break;
        default: {
            result = win32::def_window_proc(window, message, w_param, l_param);
        } 
    }

    return result;
}

fn int main() @winmain {
    HInstance h_instance = win32::get_module_handle(null);

    WndClassA window_class = {
        .style = WndClassStyles.CS_OWNDC | WndClassStyles.CS_HREDRAW | WndClassStyles.CS_VREDRAW,
        .lpfnWndProc = &main_window_callback,
        .hInstance = h_instance,
        .lpszClassName = "C3MadeHeroWindowClass",
    };

    if (win32::register_class(&window_class) == 0) {
        win32::output_debug_string("Failed to register window_class");
        return -1;
    };

    HWnd window = win32::create_window_ex(
        (WindowExStyle)0,
        window_class.lpszClassName,
        "C3Made Hero",
        WindowStyle.WS_OVERLAPPEDWINDOW | WindowStyle.WS_VISIBLE,
        win32::CW_USEDEFAULT,
        win32::CW_USEDEFAULT,
        win32::CW_USEDEFAULT,
        win32::CW_USEDEFAULT,
        null,
        null,
        h_instance,
        null,
    );

    if (!window) {
        // TODO: logging
        return -1;
    }

    int x_offset = 0;
    int y_offset = 0;

    while (running) {
        Msg message;
        while (win32::peek_message(&message, null, 0, 0, PeekMessageRemoveType.PM_REMOVE)) {
            if (message.message == win32::WM_QUIT) {
                running = false;
            }
            win32::translate_message(&message);
            win32::dispatch_message(&message);
        }

        render_weird_gradient(x_offset++, y_offset);

        Hdc device_context = win32::get_dc(window);
        Rect client_rect;
        win32::get_client_rect(window, &client_rect);
        int window_width = client_rect.right - client_rect.left;
        int window_height = client_rect.bottom - client_rect.top;
        update_window(device_context, &client_rect, 0, 0, window_width, window_height);
        win32::release_dc(window, device_context);
    }

    return 0;
}
