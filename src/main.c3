module main;

import std::atomic;
import win32;

const int BYTES_PER_PIXEL = 4;
const double FIXED_DT = 1.0 / 60.0;
const int MAX_UPDATES_PER_FRAME = 8;

Atomic{bool} running;
HWnd window;
Handle render_thread;
Hdc device;
BitmapInfo bitmap_info;
HBitmap hbitmap;
HBitmap prev_hbitmap;
void* bitmap_memory;
int bitmap_width;
int bitmap_height;

int x_offset;
int y_offset;
long perf_freq;
long last_counter;
double accumulator;

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

fn void free_dib_section() {
    if (device) {
        win32::select_object(device, prev_hbitmap);
        win32::delete_dc(device);
        device = null;
        prev_hbitmap = null;
    }
    if (hbitmap) {
        win32::delete_object(hbitmap);
        hbitmap = null;
    }

    bitmap_memory = null;
}

fn void resize_dib_section(int width, int height) {
    free_dib_section();

    bitmap_width = width;
    bitmap_height = height;

    if (width <= 0 || height <= 0) return;

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

fn void reset_frame_timer() {
    win32::query_performance_counter(&last_counter);
    accumulator = 0.0;
}

fn void process_game_frame(HWnd target_window) {
    Rect client_rect;
    win32::get_client_rect(target_window, &client_rect);
    int window_width = client_rect.right - client_rect.left;
    int window_height = client_rect.bottom - client_rect.top;

    if (window_width != bitmap_width || window_height != bitmap_height) {
        resize_dib_section(window_width, window_height);
    }

    long now = 0;
    win32::query_performance_counter(&now);

    double delta_seconds = (double)(now - last_counter) / (double)perf_freq;
    last_counter = now;

    if (delta_seconds > 0.25) delta_seconds = 0.25;

    accumulator += delta_seconds;

    int updates_this_frame = 0;
    while (accumulator >= FIXED_DT && updates_this_frame < MAX_UPDATES_PER_FRAME) {
        x_offset += 1;
        accumulator -= FIXED_DT;
        updates_this_frame += 1;
    }

    if (updates_this_frame == MAX_UPDATES_PER_FRAME) {
        accumulator = 0.0;
    }

    if (bitmap_memory) {
        render_weird_gradient(x_offset, y_offset);
    }

    Hdc window_device = win32::get_dc(target_window);
    if (window_device) {
        update_window(window_device, &client_rect, 0, 0, window_width, window_height);
        win32::release_dc(target_window, window_device);
    }
}

fn uint render_thread_proc(void* parameter) {
    HWnd target_window = (HWnd)parameter;

    win32::query_performance_frequency(&perf_freq);
    reset_frame_timer();

    while (running.load()) {
        process_game_frame(target_window);
        win32::sleep(1);
    }

    return 0;
}

fn void shutdown() {
    running.store(false);

    if (render_thread) {
        win32::wait_for_single_object(render_thread, win32::INFINITE);
        win32::close_handle(render_thread);
        render_thread = null;
    }

    free_dib_section();

    if (window) {
        win32::destroy_window(window);
        window = null;
    }
}

fn LResult main_window_callback(
    HWnd window,
    uint message,
    WParam w_param,
    LParam l_param,
) {
    LResult result = 0;

    switch (message) {
        case win32::WM_CLOSE: case win32::WM_DESTROY: {
            running.store(false);
        } break;
        default: {
            result = win32::def_window_proc(window, message, w_param, l_param);
        } 
    }

    return result;
}

fn int main() @winmain {
    defer shutdown();

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

    window = win32::create_window_ex(
        (WindowExStyle)0,
        window_class.lpszClassName,
        "C3Made Hero",
        WindowStyle.WS_OVERLAPPEDWINDOW | WindowStyle.WS_VISIBLE,
        win32::CW_USEDEFAULT, win32::CW_USEDEFAULT,
        win32::CW_USEDEFAULT, win32::CW_USEDEFAULT,
        null, null,
        h_instance,
        null,
    );

    if (!window) {
        return -1;
    }

    running.store(true);

    uint render_thread_id = 0;
    render_thread = win32::create_thread(
        null,
        0,
        &render_thread_proc,
        window,
        ThreadCreationFlags.THREAD_CREATE_RUN_IMMEDIATELY,
        &render_thread_id,
    );

    if (!render_thread) {
        return -1;
    }

    while (running.load()) {
        Msg message;
        while (win32::peek_message(&message, null, 0, 0, PeekMessageRemoveType.PM_REMOVE)) {
            if (message.message == win32::WM_QUIT) {
                running.store(false);
            }
            win32::translate_message(&message);
            win32::dispatch_message(&message);
        }

        win32::sleep(1);
    }

    return 0;
}
