module game;

import win32;
import game_api;
import std::core::mem;
import std::core::mem::alloc;
import std::core::mem::allocators;

const ushort BMP_FILE_TYPE = 0x4d42;
const ushort BMP_BITS_PER_PIXEL = 32;
const ushort BMP_REQUIRED_PLANES = 1;
const uint BMP_INFO_HEADER_SIZE = 40;
const uint BMP_INFO_HEADER_SIZE_V3 = 56;

faultdef BMP_MEMORY_UNAVAILABLE;
faultdef BMP_FILE_READ_FAILED;
faultdef BMP_FILE_TOO_SMALL;
faultdef BMP_UNSUPPORTED_FORMAT;
faultdef BMP_PIXEL_DATA_OUT_OF_BOUNDS;

struct BitmapHeader @packed {
	ushort file_type;
	uint file_size;
	ushort reserved1;
	ushort reserved2;
	uint bitmap_offset;
	uint size;
	int width;
	int height;
	ushort planes;
	ushort bits_per_pixel;
}

struct LoadedBitmap {
	int width;
	int height;
	char* pixels;
}

const int TILE_COUNT_X = 17;
const int TILE_COUNT_Y = 9;
const int TILE_SIDE_IN_PIXELS = 16;
const uint TILE_WALL = 0xFFFFFFFF;

struct TileMap {
	int tile_count_x;
	int tile_count_y;
	int tile_side_in_pixels;
	uint[TILE_COUNT_X][TILE_COUNT_Y] tiles;
}

struct World {
	TileMap tile_map;
	LoadedBitmap spritesheet;
	int spritesheet_columns;
	LoadedBitmap wall_bitmap;
}

fn bool tilemap_is_solid(TileMap* tile_map, int x, int y) {
	if (x < 0 || y < 0 || x >= tile_map.tile_count_x || y >= tile_map.tile_count_y) {
		return true;
	}
	return tile_map.tiles[y][x] == TILE_WALL;
}

struct GameState {
	int x_offset;
	int y_offset;
	double accumulator;
	LoadedBitmap test;
	World world;
}

const double FIXED_DT = 1.0 / 60.0;

fn void debug_crash_with_bmp_error(char* error_name, String asset_name) {
	(void)win32::message_box(
		null,
		error_name,
		asset_name.ptr,
		win32::MessageboxStyle.MB_OK | win32::MessageboxStyle.MB_ICONERROR
	);
	win32::exit_process(1);
}

fn LoadedBitmap? debug_load_bmp(GameMemory* memory, String filename) {
	LoadedBitmap result;
	if (!memory || !memory.debug_read_file) {
		debug_crash_with_bmp_error("BMP_MEMORY_UNAVAILABLE", filename);
		return BMP_MEMORY_UNAVAILABLE~;
	}

	char[]? loaded_file = memory.debug_read_file(memory.permanent, filename);
	if (catch loaded_file) {
		debug_crash_with_bmp_error("BMP_FILE_READ_FAILED", filename);
		return BMP_FILE_READ_FAILED~;
	}

	if (loaded_file.len < BitmapHeader::size) {
		debug_crash_with_bmp_error("BMP_FILE_TOO_SMALL", filename);
		return BMP_FILE_TOO_SMALL~;
	}

	BitmapHeader* header = (BitmapHeader*)loaded_file.ptr;
	if (header.file_type != BMP_FILE_TYPE
		|| (header.size != BMP_INFO_HEADER_SIZE && header.size != BMP_INFO_HEADER_SIZE_V3)
	    ||  header.planes != BMP_REQUIRED_PLANES
	    ||  header.bits_per_pixel != BMP_BITS_PER_PIXEL
	    ||  header.width <= 0
	    ||  header.height <= 0
	) {
		debug_crash_with_bmp_error("BMP_UNSUPPORTED_FORMAT", filename);
		return BMP_UNSUPPORTED_FORMAT~;
	}

	ulong pixel_count = (ulong)header.width * (ulong)header.height;
	ulong pixel_bytes = pixel_count * uint::size;
	ulong bitmap_offset = (ulong)header.bitmap_offset;
	ulong file_size = (ulong)loaded_file.len;
	if (bitmap_offset < BitmapHeader::size || bitmap_offset > file_size || pixel_bytes > file_size - bitmap_offset) {
		debug_crash_with_bmp_error("BMP_PIXEL_DATA_OUT_OF_BOUNDS", filename);
		return BMP_PIXEL_DATA_OUT_OF_BOUNDS~;
	}

	// Accepts both the plain 40-byte header and Aseprite/Photoshop's 56-byte
	// BITMAPV3INFOHEADER (adds explicit BGRA channel masks); pixels are copied
	// directly either way since both use the same B,G,R,A byte order.
	result.pixels = loaded_file.ptr + header.bitmap_offset;
	result.width = header.width;
	result.height = header.height;
	return result;
}

fn LoadedBitmap debug_load_bmp_or_crash(GameMemory* memory, String filename) {
	LoadedBitmap? bitmap = debug_load_bmp(memory, filename);
	if (catch err = bitmap) {
		debug_crash_with_bmp_error(err.description, filename);
		return {};
	}
	return bitmap;
}

<*
  Draws a solid color background to the buffer.
  The color is specified in ARGB format (0xAARRGGBB).
*>
fn void draw_background(GameOffscreenBuffer* buffer, uint color) {
	if (!buffer || !buffer.memory) {
		return;
	}

	char* row = (char*)buffer.memory;
	for (int y = 0; y < buffer.height; y++) {
		uint* pixel = (uint*)row;
		for (int x = 0; x < buffer.width; x++) {
			*pixel++ = color;
		}
		row += buffer.pitch;
	}
}

<*
  Draws a weird blue & green gradient to the buffer.
  The gradient is based on the x and y offsets of the game state.
*>
fn void draw_weird_gradient(GameOffscreenBuffer* buffer, GameState* state) {
	if (!buffer || !buffer.memory) {
		return;
	}

	char* row = (char*)buffer.memory;
	for (int y = 0; y < buffer.height; y++) {
		uint* pixel = (uint*)row;
		for (int x = 0; x < buffer.width; x++) {
			uint blue = (uint)((x + state.x_offset) & 0xff);
			uint green = (uint)((y + state.y_offset) & 0xff);
			*pixel++ = (green << 8) | blue;
		}
		row += buffer.pitch;
	}
}

<*
  Draws a bitmap to the buffer at the specified real_x and real_y coordinates.
  The bitmap is drawn using the specified source rectangle (src_x, src_y, src_w, src_h).
  If the source rectangle is not specified, the entire bitmap is drawn.
*>
fn void draw_bitmap(
	GameOffscreenBuffer* buffer,
	LoadedBitmap* bitmap,
	float real_x,
	float real_y,
	int src_x = 0,
	int src_y = 0,
	int src_w = 0,
	int src_h = 0,
) {
	if (!buffer || !buffer.memory || !bitmap || !bitmap.pixels) {
		return;
	}

	int use_w = src_w != 0 ? src_w : bitmap.width;
	int use_h = src_h != 0 ? src_h : bitmap.height;
	if (use_w <= 0 || use_h <= 0) {
		return;
	}
	if (src_x < 0 || src_y < 0 || src_x + use_w > bitmap.width || src_y + use_h > bitmap.height) {
		return;
	}

	int min_x = (int)real_x;
	int min_y = (int)real_y;
	int max_x = min_x + use_w;
	int max_y = min_y + use_h;

	int src_offset_x = 0;
	int src_offset_y = 0;
	if (min_x < 0) {
		src_offset_x = -min_x;
		min_x = 0;
	}
	if (min_y < 0) {
		src_offset_y = -min_y;
		min_y = 0;
	}
	if (max_x > buffer.width) {
		max_x = buffer.width;
	}
	if (max_y > buffer.height) {
		max_y = buffer.height;
	}
	if (min_x >= max_x || min_y >= max_y) {
		return;
	}

	char* source_row = bitmap.pixels
		+ (long)uint::size * (long)(bitmap.width * (bitmap.height - 1 - src_y - src_offset_y) + src_x + src_offset_x);
	char* dest_row = (char*)buffer.memory
		+ min_x * buffer.bytes_per_pixel
		+ min_y * buffer.pitch;

	for (int y = min_y; y < max_y; y++) {
		uint* dest = (uint*)dest_row;
		char* source = source_row;
		for (int x = min_x; x < max_x; x++) {
			*dest++ = mem::load((uint*)source, 1);
			source += uint::size;
		}
		dest_row += buffer.pitch;
		source_row -= (long)bitmap.width * (long)uint::size;
	}
}

<*
  Draws the tilemap of the world to the buffer.
  Tilemap is drawn from top-left to bottom-right, with each tile being a square of size tile_side_in_pixels.
  Tilemap is drawn using the spritesheet, with each tile being
  a cell in the spritesheet, with the cell being determined by the tile value.
*>
fn void draw_tilemap(GameOffscreenBuffer* buffer, World* world) {
	if (!buffer || !world) {
		return;
	}

	TileMap* tile_map = &world.tile_map;
	if (tile_map.tile_count_x <= 0 ||
		tile_map.tile_count_y <= 0 ||
		tile_map.tile_count_x > TILE_COUNT_X ||
		tile_map.tile_count_y > TILE_COUNT_Y ||
		tile_map.tile_side_in_pixels <= 0) {
		return;
	}

	int side = tile_map.tile_side_in_pixels;
	for (int y = 0; y < tile_map.tile_count_y; y++) {
		for (int x = 0; x < tile_map.tile_count_x; x++) {
			uint tile_value = tile_map.tiles[y][x];
			float dest_x = (float)(x * side);
			float dest_y = (float)(y * side);

			if (tile_value == TILE_WALL) {
				draw_bitmap(buffer, &world.wall_bitmap, dest_x, dest_y, 0, 0, side, side);
				continue;
			}

			if (world.spritesheet_columns <= 0) {
				continue;
			}
			int cell_x = (int)tile_value % world.spritesheet_columns;
			int cell_y = (int)tile_value / world.spritesheet_columns;
			draw_bitmap(
				buffer,
				&world.spritesheet,
				dest_x,
				dest_y,
				cell_x * side,
				cell_y * side,
				side,
				side
			);
		}
	}
}

fn void game_update_and_render(GameMemory* memory, GameOffscreenBuffer* buffer, GameInput* input) @export("GameUpdateAndRender") {
	GameState* state = (GameState*)memory.game_state;

	if (!memory.is_initialized) {
		state = alloc::new(memory.permanent, GameState);
		if (!state) {
			return;
		}

		state.x_offset = 0;
		state.y_offset = 0;
		state.accumulator = 0;
		state.test = debug_load_bmp_or_crash(memory, "test.bmp");
		state.world.tile_map.tile_count_x = TILE_COUNT_X;
		state.world.tile_map.tile_count_y = TILE_COUNT_Y;
		state.world.tile_map.tile_side_in_pixels = TILE_SIDE_IN_PIXELS;
		state.world.spritesheet = debug_load_bmp_or_crash(memory, "tile.bmp");
		state.world.wall_bitmap = debug_load_bmp_or_crash(memory, "wall.bmp");

		state.world.spritesheet_columns = state.world.spritesheet.width / TILE_SIDE_IN_PIXELS;
		if (state.world.spritesheet_columns < 1) {
			state.world.spritesheet_columns = 1;
		}
		int spritesheet_rows = state.world.spritesheet.height / TILE_SIDE_IN_PIXELS;
		if (spritesheet_rows < 1) {
			spritesheet_rows = 1;
		}
		int cell_count = state.world.spritesheet_columns * spritesheet_rows;
		if (cell_count < 1) {
			cell_count = 1;
		}
		for (int y = 0; y < TILE_COUNT_Y; y++) {
			for (int x = 0; x < TILE_COUNT_X; x++) {
				bool is_border = x == 0 || y == 0 || x == TILE_COUNT_X - 1 || y == TILE_COUNT_Y - 1;
				state.world.tile_map.tiles[y][x] = is_border ? TILE_WALL : (uint)((x + y) % cell_count);
			}
		}

		memory.game_state = state;
		memory.is_initialized = true;
	}

	state.accumulator += input.dt;
	while (state.accumulator >= FIXED_DT) {
		state.x_offset += 1;
		state.accumulator -= FIXED_DT;
	}

	if (!buffer || !buffer.memory) {
		return;
	}


	draw_background(buffer, 0xFF000000);
	// draw_weird_gradient(buffer, state);
	// draw_bitmap(buffer, &state.test, (float)state.x_offset, 0);
	draw_tilemap(buffer, &state.world);
}
