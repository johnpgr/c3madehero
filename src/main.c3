module main;

import win32;

const int BYTES_PER_PIXEL = 4;

bool running = true;

HWnd window;
Hdc device;
BitmapInfo bitmap_info;
HBitmap hbitmap;
HBitmap prev_hbitmap;
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
    if (device) {
        win32::select_object(device, prev_hbitmap);
        win32::delete_dc(device);
        device = null;
    }
    if (hbitmap) {
        win32::delete_object(hbitmap);
        hbitmap = null;
    }

    bitmap_width = width;
    bitmap_height = height;

    bitmap_info.bmiHeader.biSize = BitmapInfoHeader::size;
	bitmap_info.bmiHeader.biWidth = bitmap_width;
	bitmap_info.bmiHeader.biHeight = -bitmap_height;
	bitmap_info.bmiHeader.biPlanes = 1;
	bitmap_info.bmiHeader.biBitCount = 32;
	bitmap_info.bmiHeader.biCompression = (uint)BiCompression.BI_RGB;

	device = win32::create_compatible_dc(null);
    hbitmap = win32::create_dib_section(
        device, &bitmap_info,
        DibUsage.DIB_RGB_COLORS,
        &bitmap_memory,
        null, 0,
    );
    prev_hbitmap = win32::select_object(device, hbitmap);
}

fn void update_window(Hdc window_device, Rect* client_rect, int x, int y, int width, int height) {
    if (!bitmap_memory || !device) return;

    if (width == bitmap_width && height == bitmap_height) {
        win32::bit_blt(
            window_device,
            x, y, width, height,
            device, 0, 0,
            RopCode.SRCCOPY,
        );
        return;
    }

    win32::stretch_blt(
        window_device,
        x, y, width, height,
        device,
        0, 0, bitmap_width, bitmap_height,
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
        // case win32::WM_PAINT: {
        //     PaintStruct paint;

        //     Hdc hdc = win32::begin_paint(window, &paint);
        //     defer win32::end_paint(window, &paint);
        // } break;
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

    // minimal fixed-step timing
    long perf_freq = 0;
    long last_counter = 0;
    double accumulator = 0.0;
    double fixed_dt = 1.0 / 60.0;

    win32::query_performance_frequency(&perf_freq);
    win32::query_performance_counter(&last_counter);

    while (running) {
        Msg message;
        while (win32::peek_message(&message, null, 0, 0, PeekMessageRemoveType.PM_REMOVE)) {
            if (message.message == win32::WM_QUIT) {
                running = false;
            }
            win32::translate_message(&message);
            win32::dispatch_message(&message);
        }

		if (bitmap_memory) {
            long now = 0;
            win32::query_performance_counter(&now);
            double delta_seconds = (double)(now - last_counter) / (double)perf_freq;
            last_counter = now;

            accumulator += delta_seconds;
            if (accumulator > 0.25) accumulator = 0.25;

            while (accumulator >= fixed_dt) {
                x_offset += 1;
                accumulator -= fixed_dt;
            }

            render_weird_gradient(x_offset, y_offset);
        }

        Hdc window_device = win32::get_dc(window);
        Rect client_rect; win32::get_client_rect(window, &client_rect);
        int window_width = client_rect.right - client_rect.left;
        int window_height = client_rect.bottom - client_rect.top;

        update_window(window_device, &client_rect, 0, 0, window_width, window_height);
        win32::release_dc(window, window_device);
        win32::sleep(1);
    }

    if (device) {
        win32::select_object(device, prev_hbitmap);
        win32::delete_dc(device);
        device = null;
    }
    if (hbitmap) {
        win32::delete_object(hbitmap);
        hbitmap = null;
    }
    bitmap_memory = null;

    return 0;
}
