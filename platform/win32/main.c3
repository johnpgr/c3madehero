module main;

import win32;
import game_api;
import std::core::mem;
import std::core::mem::alloc;
import std::core::mem::allocators;
import std::io;
import std::io::file;

const uptr PERSISTENT_MEMORY_SIZE = 1 * mem::GB;
const uptr TRANSIENT_MEMORY_SIZE = 64 * mem::MB;

const int BYTES_PER_PIXEL = 4;
const double MAX_DT = 0.25;

const int WINDOW_WIDTH = 320;
const int WINDOW_HEIGHT = 180;

const WindowStyle FIXED_WINDOW_STYLE =
	WindowStyle.WS_OVERLAPPED |
	WindowStyle.WS_CAPTION |
	WindowStyle.WS_SYSMENU |
	WindowStyle.WS_MINIMIZEBOX |
	WindowStyle.WS_VISIBLE;

const WindowStyle RESIZABLE_WINDOW_STYLE =
	WindowStyle.WS_OVERLAPPEDWINDOW |
	WindowStyle.WS_VISIBLE;

const int HEADLESS_SCREENSHOT_WIDTH = 960;
const int HEADLESS_SCREENSHOT_HEIGHT = 540;

const ushort BMP_FILE_TYPE = 0x4d42;
const ushort BMP_BITS_PER_PIXEL = 32;
const ushort BMP_REQUIRED_PLANES = 1;
const uint BMP_INFO_HEADER_SIZE = 40;
const uint BMP_COMPRESSION_RGB = 0;

const char* GAME_DLL_PATH = "c3madehero_game.dll";
const char* GAME_DLL_TEMP_PATH = "c3madehero_game_temp.dll";

faultdef FILE_WRITE_TIME_UNAVAILABLE;
faultdef GAME_DLL_COPY_FAILED;
faultdef GAME_DLL_LOAD_FAILED;
faultdef GAME_DLL_SYMBOL_MISSING;
faultdef CANVAS_DC_CREATE_FAILED;
faultdef CANVAS_BITMAP_CREATE_FAILED;
faultdef CANVAS_SELECT_FAILED;
faultdef TIMING_QUERY_FAILED;
faultdef MEMORY_RESERVE_FAILED;
faultdef WINDOW_CLASS_REGISTER_FAILED;
faultdef WINDOW_CREATE_FAILED;
faultdef INVALID_SCREENSHOT_BUFFER;

struct BmpWriteHeader @packed {
	ushort file_type;
	uint file_size;
	ushort reserved1;
	ushort reserved2;
	uint bitmap_offset;
	uint info_header_size;
	int width;
	int height;
	ushort planes;
	ushort bits_per_pixel;
	uint compression;
	uint image_size;
	int x_pixels_per_meter;
	int y_pixels_per_meter;
	uint colors_used;
	uint important_colors;
}

struct Canvas2D {
	BitmapInfo bitmap_info;
	Hdc device;
	HBitmap hbitmap;
	HBitmap prev_hbitmap;
	GameOffscreenBuffer buffer;
}

struct FrameTiming {
	long perf_freq;
	long last_counter;
}

struct GameCode {
	HModule library;
	GameUpdateAndRenderFn update_and_render;
	win32::FileTime last_write_time;
}

struct App {
	bool running;
	HWnd window;
	FrameTiming timing;
	GameCode game_code;
	GameMemory game_memory;
	Canvas2D canvas;
	Vmem persistent_allocator;
	Vmem transient_allocator;
}

fn void App.stop(&self) {
	self.running = false;
}

fn char[]? debug_read_entire_file(Vmem* allocator, String filename) {
	File opened_file = file::open(filename, "rb")!;
	defer (void)opened_file.close();

	long len = opened_file.size()!;
	if (len > sz::max) {
		return io::OUT_OF_SPACE~;
	}
	if (len == 0) {
		return (char[])"";
	}

	char* data = allocator.acquire((sz)len, NO_ZERO, 0)!;
	return io::read_buffer_to_end(opened_file, data[:len]);
}

fn void? get_last_write_time(char* filename, win32::FileTime* last_write_time) {
	Win32FindDataA find_data;
	Handle find_handle = win32::find_first_file(filename, &find_data);
	if (find_handle == win32::INVALID_HANDLE_VALUE) {
		return FILE_WRITE_TIME_UNAVAILABLE~;
	}

	*last_write_time = find_data.ftLastWriteTime;
	win32::find_close(find_handle);
}

fn void GameCode.unload(&self) {
	if (self.library) {
		win32::free_library(self.library);
		self.library = null;
	}

	self.update_and_render = null;
}

fn void? GameCode.load(&self, char* source_dll_path, char* temp_dll_path) {
	win32::FileTime source_write_time;
	if (catch get_last_write_time(source_dll_path, &source_write_time)) {
		win32::output_debug_string("Failed to get game DLL write time\n");
		return FILE_WRITE_TIME_UNAVAILABLE~;
	}

	if (!win32::copy_file(source_dll_path, temp_dll_path, (Bool)false)) {
		win32::output_debug_string("Failed to copy game DLL to temp file\n");
		return GAME_DLL_COPY_FAILED~;
	}

	HModule library = win32::load_library(temp_dll_path);
	if (!library) {
		win32::output_debug_string("Failed to load game DLL\n");
		return GAME_DLL_LOAD_FAILED~;
	}

	FarProc update_and_render_proc = win32::get_proc_address(library, "GameUpdateAndRender");
	if (!update_and_render_proc) {
		win32::output_debug_string("Failed to find GameUpdateAndRender in game DLL\n");
		win32::free_library(library);
		return GAME_DLL_SYMBOL_MISSING~;
	}

	self.library = library;
	self.update_and_render = bitcast(update_and_render_proc, GameUpdateAndRenderFn);
	self.last_write_time = source_write_time;
}

fn void? GameCode.reload_if_changed(&self, char* source_dll_path, char* temp_dll_path) {
	win32::FileTime source_write_time;
	if (catch get_last_write_time(source_dll_path, &source_write_time)) {
		return FILE_WRITE_TIME_UNAVAILABLE~;
	}

	if (win32::compare_file_time(&source_write_time, &self.last_write_time) <= 0) {
		return;
	}

	self.unload();
	self.load(source_dll_path, temp_dll_path)!;
}

fn void Canvas2D.release(&self) {
	if (self.device) {
		win32::select_object(self.device, self.prev_hbitmap);
		win32::delete_dc(self.device);
		self.device = null;
		self.prev_hbitmap = null;
	}

	if (self.hbitmap) {
		win32::delete_object(self.hbitmap);
		self.hbitmap = null;
	}

	self.buffer = {};
}

fn void? Canvas2D.resize(&self, int width, int height) {
	if (width == self.buffer.width && height == self.buffer.height) {
		return;
	}

	self.release();

	if (width <= 0 || height <= 0) {
		return;
	}

	BitmapInfo bitmap_info;
	bitmap_info.bmiHeader.biSize = BitmapInfoHeader::size;
	bitmap_info.bmiHeader.biWidth = width;
	bitmap_info.bmiHeader.biHeight = -height;
	bitmap_info.bmiHeader.biPlanes = 1;
	bitmap_info.bmiHeader.biBitCount = 32;
	bitmap_info.bmiHeader.biCompression = (uint)BiCompression.BI_RGB;

	Hdc device = win32::create_compatible_dc(null);
	if (!device) {
		return CANVAS_DC_CREATE_FAILED~;
	}

	void* memory = null;
	HBitmap hbitmap = win32::create_dib_section(
		device, &bitmap_info,
		DibUsage.DIB_RGB_COLORS,
		&memory,
		null, 0,
	);

	if (!hbitmap || !memory) {
		if (hbitmap) {
			win32::delete_object(hbitmap);
		}
		win32::delete_dc(device);
		return CANVAS_BITMAP_CREATE_FAILED~;
	}

	HBitmap prev_hbitmap = win32::select_object(device, hbitmap);
	if (!prev_hbitmap) {
		win32::delete_object(hbitmap);
		win32::delete_dc(device);
		return CANVAS_SELECT_FAILED~;
	}

	self.bitmap_info = bitmap_info;
	self.device = device;
	self.hbitmap = hbitmap;
	self.prev_hbitmap = prev_hbitmap;
	self.buffer = {
		.memory = memory,
		.width = width,
		.height = height,
		.pitch = width * BYTES_PER_PIXEL,
		.bytes_per_pixel = BYTES_PER_PIXEL,
	};
}

fn void? FrameTiming.begin(&self) {
	if (!win32::query_performance_frequency(&self.perf_freq) || self.perf_freq <= 0) {
		return TIMING_QUERY_FAILED~;
	}

	if (!win32::query_performance_counter(&self.last_counter)) {
		return TIMING_QUERY_FAILED~;
	}
}

fn double FrameTiming.consume_dt(&self) {
	long now = 0;
	if (!win32::query_performance_counter(&now)) {
		return 0.0;
	}

	double delta_seconds = (double)(now - self.last_counter) / (double)self.perf_freq;
	self.last_counter = now;

	if (delta_seconds > MAX_DT) {
		delta_seconds = MAX_DT;
	}

	return delta_seconds;
}

fn void? write_bmp_file(String path, GameOffscreenBuffer* buffer) {
	if (!buffer ||
		!buffer.memory ||
		buffer.width <= 0 ||
		buffer.height <= 0 ||
		buffer.bytes_per_pixel != BYTES_PER_PIXEL ||
		buffer.pitch < buffer.width * BYTES_PER_PIXEL) {
		return INVALID_SCREENSHOT_BUFFER~;
	}

	uint row_bytes = (uint)(buffer.width * BYTES_PER_PIXEL);
	uint image_size = row_bytes * (uint)buffer.height;
	BmpWriteHeader header = {
		.file_type = BMP_FILE_TYPE,
		.file_size = (uint)BmpWriteHeader::size + image_size,
		.reserved1 = 0,
		.reserved2 = 0,
		.bitmap_offset = (uint)BmpWriteHeader::size,
		.info_header_size = BMP_INFO_HEADER_SIZE,
		.width = buffer.width,
		.height = buffer.height,
		.planes = BMP_REQUIRED_PLANES,
		.bits_per_pixel = BMP_BITS_PER_PIXEL,
		.compression = BMP_COMPRESSION_RGB,
		.image_size = image_size,
		.x_pixels_per_meter = 0,
		.y_pixels_per_meter = 0,
		.colors_used = 0,
		.important_colors = 0,
	};

	File output_file = file::open(path, "wb")!;
	defer (void)output_file.close();

	char* header_bytes = (char*)&header;
	output_file.write(header_bytes[:BmpWriteHeader::size])!;

	int y = buffer.height;
	while (y > 0) {
		y--;
		char* row = (char*)buffer.memory + (long)y * (long)buffer.pitch;
		output_file.write(row[:row_bytes])!;
	}
}

fn void App.present(&self, Canvas2D* canvas, int window_width, int window_height) {
	if (!canvas.buffer.memory || !canvas.device || window_width <= 0 || window_height <= 0) {
		return;
	}

	Hdc window_device = win32::get_dc(self.window);
	if (window_device) {
		if (window_width == canvas.buffer.width && window_height == canvas.buffer.height) {
			win32::bit_blt(
				window_device,
				0, 0, window_width, window_height,
				canvas.device, 0, 0,
				RopCode.SRCCOPY,
			);
		} else {
			win32::stretch_blt(
				window_device,
				0, 0, window_width, window_height,
				canvas.device,
				0, 0, canvas.buffer.width, canvas.buffer.height,
				RopCode.SRCCOPY,
			);
		}
		win32::release_dc(self.window, window_device);
	}
}

fn void App.process_frame(&self) {
	self.transient_allocator.reset(0);

	if (catch self.game_code.reload_if_changed(GAME_DLL_PATH, GAME_DLL_TEMP_PATH)) {
		win32::output_debug_string("Failed to reload game DLL\n");
		self.stop();
		return;
	}

	Rect client_rect;
	if (!win32::get_client_rect(self.window, &client_rect)) {
		win32::output_debug_string("Failed to query client rect\n");
		self.stop();
		return;
	}

	int window_width = client_rect.right - client_rect.left;
	int window_height = client_rect.bottom - client_rect.top;

	if (catch self.canvas.resize(window_width, window_height)) {
		win32::output_debug_string("Failed to resize canvas\n");
		self.stop();
		return;
	}

	double dt = self.timing.consume_dt();

	GameInput input = {
		.dt = dt,
		.quit_requested = !self.running,
	};

	if (self.game_code.update_and_render) {
		self.game_code.update_and_render(&self.game_memory, &self.canvas.buffer, &input);
	}

	self.present(&self.canvas, window_width, window_height);
}

fn void App.shutdown(&self) {
	self.stop();
	self.game_code.unload();
	self.canvas.release();
	self.persistent_allocator.free();
	self.transient_allocator.free();

	if (self.window) {
		win32::destroy_window(self.window);
		self.window = null;
	}
}

fn void? App.init_memory(&self) {
	if (catch self.persistent_allocator.init((sz)PERSISTENT_MEMORY_SIZE)) {
		win32::output_debug_string("Failed to reserve persistent memory\n");
		return MEMORY_RESERVE_FAILED~;
	}

	if (catch self.transient_allocator.init((sz)TRANSIENT_MEMORY_SIZE)) {
		win32::output_debug_string("Failed to reserve transient memory\n");
		self.persistent_allocator.free();
		return MEMORY_RESERVE_FAILED~;
	}

	self.game_memory = {
		.permanent = &self.persistent_allocator,
		.transient = &self.transient_allocator,
		.is_initialized = false,
		.game_state = null,
		.debug_read_file = &debug_read_entire_file,
	};
}

fn void? App.init(&self, HInstance h_instance, int window_width, int window_height, WindowStyle style) {
	self.init_memory()!;
	self.create_window(h_instance, window_width, window_height, style)!;

	if (catch self.game_code.load(GAME_DLL_PATH, GAME_DLL_TEMP_PATH)) {
		win32::output_debug_string("Failed to load initial game DLL\n");
		return GAME_DLL_LOAD_FAILED~;
	}
}

fn void? App.create_window(&self, HInstance h_instance, int width, int height, WindowStyle window_style) {
	WndClassA window_class = {
		.style = WndClassStyles.CS_OWNDC | WndClassStyles.CS_HREDRAW | WndClassStyles.CS_VREDRAW,
		.lpfnWndProc = &main_window_proc,
		.hInstance = h_instance,
		.hCursor = win32::load_cursor(null, (char*)win32::IDC_ARROW),
		.lpszClassName = "C3MadeHeroWindowClass",
	};

	if (win32::register_class(&window_class) == 0) {
		win32::output_debug_string("Failed to register window class\n");
		return WINDOW_CLASS_REGISTER_FAILED~;
	};

	self.window = win32::create_window_ex(
		(WindowExStyle)0,
		window_class.lpszClassName,
		"C3Made Hero",
		window_style,
		win32::CW_USEDEFAULT, win32::CW_USEDEFAULT,
		width, height,
		null, null,
		h_instance,
		self,
	);

	if (!self.window) {
		win32::output_debug_string("Failed to create main window\n");
		return WINDOW_CREATE_FAILED~;
	}
}

fn void App.run(&self) {
	if (catch self.timing.begin()) {
		win32::output_debug_string("Failed to initialize frame timing\n");
		return;
	}

	self.running = true;

	while (self.running) {
		Msg message;
		while (win32::peek_message(&message, null, 0, 0, PeekMessageRemoveType.PM_REMOVE)) {
			if (message.message == win32::WM_QUIT) {
				self.stop();
			}
			win32::translate_message(&message);
			win32::dispatch_message(&message);
		}

		if (!self.running) break;

		self.process_frame();
	}
}

fn int App.run_headless_screenshot(&self, String output_path) {
	if (catch self.init_memory()) {
		win32::output_debug_string("Failed to initialize headless memory\n");
		return -1;
	}

	if (catch self.game_code.load(GAME_DLL_PATH, GAME_DLL_TEMP_PATH)) {
		win32::output_debug_string("Failed to load initial game DLL\n");
		return -1;
	}

	if (catch self.canvas.resize(HEADLESS_SCREENSHOT_WIDTH, HEADLESS_SCREENSHOT_HEIGHT)) {
		win32::output_debug_string("Failed to resize headless canvas\n");
		return -1;
	}

	GameInput input = {
		.dt = 0.0,
		.quit_requested = false,
	};

	if (self.game_code.update_and_render) {
		self.game_code.update_and_render(&self.game_memory, &self.canvas.buffer, &input);
	}

	if (catch write_bmp_file(output_path, &self.canvas.buffer)) {
		win32::output_debug_string("Failed to write screenshot BMP\n");
		return -1;
	}

	return 0;
}

fn LResult main_window_proc(HWnd window, uint message, WParam w_param, LParam l_param) {
	LResult result = 0;

	switch (message) {
		case win32::WM_NCCREATE: {
			Createstructa* create_info = (Createstructa*)l_param;
			App* app = (App*)create_info.lpCreateParams;
			if (!app) {
				return 0;
			}

			app.window = window;
			win32::set_window_long_ptr(window, WindowLongPtrIndex.GWLP_USERDATA, (iptr)app);
			result = 1;
		} break;
		case win32::WM_CLOSE: case win32::WM_DESTROY: {
			App* app = (App*)win32::get_window_long_ptr(window, WindowLongPtrIndex.GWLP_USERDATA);
			if (app) {
				app.stop();
			}
		} break;
		case win32::WM_NCDESTROY: {
			win32::set_window_long_ptr(window, WindowLongPtrIndex.GWLP_USERDATA, 0);
			result = win32::def_window_proc(window, message, w_param, l_param);
		} break;
		default: {
			result = win32::def_window_proc(window, message, w_param, l_param);
		}
	}

	return result;
}

fn int main(String[] args) @winmain {
	String screenshot_path;
	bool should_take_screenshot = false;
	for (usz i = 0; i < args.len; i++) {
		if (args[i] == "--screenshot" && i + 1 < args.len) {
			screenshot_path = args[i + 1];
			should_take_screenshot = true;
			break;
		}
	}

	if (should_take_screenshot) {
		App app;
		defer app.shutdown();
		return app.run_headless_screenshot(screenshot_path);
	}

	HInstance h_instance = win32::get_module_handle(null);
	if (!h_instance) {
		return -1;
	};

	App app;
	if (catch app.init(h_instance, WINDOW_WIDTH, WINDOW_HEIGHT, FIXED_WINDOW_STYLE)) {
		app.shutdown();
		return -1;
	}
	defer app.shutdown();

	app.run();

	return 0;
}
