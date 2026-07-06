module game_api;

import std::core::mem::allocators;

alias DebugReadEntireFileFn = fn char[]?(Vmem*, String);

struct GameMemory {
	Vmem* permanent;
	Vmem* transient;
	bool is_initialized;
	void* game_state;
	DebugReadEntireFileFn debug_read_file;
}

struct GameOffscreenBuffer {
	void* memory;
	int width;
	int height;
	int pitch;
	int bytes_per_pixel;
}

struct GameInput {
	double dt;
	bool quit_requested;
}

alias GameUpdateAndRenderFn = fn void(GameMemory*, GameOffscreenBuffer*, GameInput*);
