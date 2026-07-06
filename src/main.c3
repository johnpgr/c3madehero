module main;

import std::atomic;
import win32;

const int BYTES_PER_PIXEL = 4;
const double FIXED_DT = 1.0 / 60.0;
const int MAX_UPDATES_PER_FRAME = 8;

struct Canvas2D {
	BitmapInfo bitmap_info;
	HBitmap hbitmap;
	HBitmap prev_hbitmap;
	void* memory;
	int width;
	int height;
}

struct State {
	int x_offset;
	int y_offset;
	long perf_freq;
	long last_counter;
	double accumulator;
}

struct App {
	Atomic{bool} running;
	Handle render_thread;
	HWnd window;
	Hdc device;
}

App global_app;
Canvas2D global_canvas;
State global_state;

fn void free_dib_section(App* app, Canvas2D* buffer) {
    if (app.device) {
        win32::select_object(app.device, buffer.prev_hbitmap);
        win32::delete_dc(app.device);
        app.device = null;
        buffer.prev_hbitmap = null;
    }
    if (buffer.hbitmap) {
        win32::delete_object(buffer.hbitmap);
        buffer.hbitmap = null;
    }

    buffer.memory = null;
}

fn void process_game_frame(App* app, Canvas2D* canvas, State* state) {
    Rect client_rect;
    win32::get_client_rect(app.window, &client_rect);
    int window_width = client_rect.right - client_rect.left;
    int window_height = client_rect.bottom - client_rect.top;

    if (window_width != canvas.width || window_height != canvas.height) {
        free_dib_section(app, canvas);
        canvas.width = window_width;
        canvas.height = window_height;

        if (window_width > 0 && window_height > 0) {
            canvas.bitmap_info.bmiHeader.biSize = BitmapInfoHeader::size;
            canvas.bitmap_info.bmiHeader.biWidth = canvas.width;
            canvas.bitmap_info.bmiHeader.biHeight = -canvas.height;
            canvas.bitmap_info.bmiHeader.biPlanes = 1;
            canvas.bitmap_info.bmiHeader.biBitCount = 32;
            canvas.bitmap_info.bmiHeader.biCompression = (uint)BiCompression.BI_RGB;

            app.device = win32::create_compatible_dc(null);
            canvas.hbitmap = win32::create_dib_section(
                app.device, &canvas.bitmap_info,
                DibUsage.DIB_RGB_COLORS,
                &canvas.memory,
                null, 0,
            );
            canvas.prev_hbitmap = win32::select_object(app.device, canvas.hbitmap);
        }
    }

    long now = 0;
    win32::query_performance_counter(&now);

    double delta_seconds = (double)(now - state.last_counter) / (double)state.perf_freq;
    state.last_counter = now;

    if (delta_seconds > 0.25) delta_seconds = 0.25;

    state.accumulator += delta_seconds;

    int updates_this_frame = 0;
    while (state.accumulator >= FIXED_DT && updates_this_frame < MAX_UPDATES_PER_FRAME) {
        state.x_offset += 1;
        state.accumulator -= FIXED_DT;
        updates_this_frame += 1;
    }

    if (updates_this_frame == MAX_UPDATES_PER_FRAME) {
        state.accumulator = 0.0;
    }

    if (canvas.memory) {
        int width = canvas.width;
        int height = canvas.height;
        int pitch = width * BYTES_PER_PIXEL;
        char* row = (char*)canvas.memory;

        for (int y = 0; y < canvas.height; y++) {
            uint* pixel = (uint*)row;
            for (int x = 0; x < canvas.width; x++) {
                char blue = (char)(x + state.x_offset);
                char green = (char)(y + state.y_offset);
                *pixel++ = ((green << 8) | blue);
            }
            row += pitch;
        }
    }

    Hdc window_device = win32::get_dc(app.window);
    if (window_device) {
        if (canvas.memory && app.device) {
            if (window_width == canvas.width && window_height == canvas.height) {
                win32::bit_blt(
                    window_device,
                    0, 0, window_width, window_height,
                    app.device, 0, 0,
                    RopCode.SRCCOPY,
                );
            } else {
                win32::stretch_blt(
                    window_device,
                    0, 0, window_width, window_height,
                    app.device,
                    0, 0, canvas.width, canvas.height,
                    RopCode.SRCCOPY,
                );
            }
        }
        win32::release_dc(app.window, window_device);
    }
}

fn void shutdown(App* app, Canvas2D* buffer) {
    app.running.store(false);

    if (app.render_thread) {
        win32::wait_for_single_object(app.render_thread, win32::INFINITE);
        win32::close_handle(app.render_thread);
        app.render_thread = null;
    }

    free_dib_section(app, buffer);

    if (app.window) {
        win32::destroy_window(app.window);
        app.window = null;
    }
}


struct RenderProcParams {
	App* app;
	State* state;
	Canvas2D* canvas;
}

fn uint render_thread_proc(void* parameter) {
	RenderProcParams* params = (RenderProcParams*)parameter;
	App* app = params.app;
	State* state = params.state;
	Canvas2D* canvas = params.canvas;

	win32::query_performance_frequency(&state.perf_freq);
	win32::query_performance_counter(&state.last_counter);
	state.accumulator = 0.0;

	while (global_app.running.load()) {
		process_game_frame(app, canvas, state);
		win32::sleep(1);
	}

	return 0;
}

fn LResult main_window_proc(HWnd window, uint message, WParam w_param, LParam l_param) {
	win32::output_debug_string("hello\n");

	LResult result = 0;

	switch (message) {
		case win32::WM_CLOSE: case win32::WM_DESTROY: {
			global_app.running.store(false);
		} break;
		default: {
			result = win32::def_window_proc(window, message, w_param, l_param);
		}
	}

	return result;
}

fn int main() @winmain {
    defer shutdown(&global_app, &global_canvas);

    HInstance h_instance = win32::get_module_handle(null);

    WndClassA window_class = {
        .style = WndClassStyles.CS_OWNDC | WndClassStyles.CS_HREDRAW | WndClassStyles.CS_VREDRAW,
        .lpfnWndProc = &main_window_proc,
        .hInstance = h_instance,
        .lpszClassName = "C3MadeHeroWindowClass",
    };

    if (win32::register_class(&window_class) == 0) {
        win32::output_debug_string("Failed to register window_class");
        return -1;
    };

    global_app.window = win32::create_window_ex(
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

    if (!global_app.window) {
        return -1;
    }

    global_app.running.store(true);

    uint render_thread_id = 0;

	RenderProcParams params = {
		.app = &global_app,
		.state = &global_state,
		.canvas = &global_canvas,
	};

    global_app.render_thread = win32::create_thread(
        null,
        0,
		&render_thread_proc,
		&params,
        ThreadCreationFlags.THREAD_CREATE_RUN_IMMEDIATELY,
        &render_thread_id,
    );

    if (!global_app.render_thread) {
        return -1;
    }

    while (global_app.running.load()) {
        Msg message;
        while (win32::peek_message(&message, null, 0, 0, PeekMessageRemoveType.PM_REMOVE)) {
            if (message.message == win32::WM_QUIT) {
                global_app.running.store(false);
            }
            win32::translate_message(&message);
            win32::dispatch_message(&message);
        }

        win32::sleep(1);
    }

    return 0;
}
