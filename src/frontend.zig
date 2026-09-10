const std = @import("std");
const Chip8 = @import("chip8.zig").Chip8;
const Runtime = @import("runtime.zig").Runtime;
const sdl = @cImport({
    @cInclude("SDL3/SDL.h");
});

const KeyBinding = struct {
    chip_key: usize,
    scancode: c_uint,
};

// Reproduce the CHIP-8 hexadecimal keypad on the left side of the keyboard.
const key_bindings = [_]KeyBinding{
    .{ .chip_key = 0x0, .scancode = sdl.SDL_SCANCODE_X },
    .{ .chip_key = 0x1, .scancode = sdl.SDL_SCANCODE_1 },
    .{ .chip_key = 0x2, .scancode = sdl.SDL_SCANCODE_2 },
    .{ .chip_key = 0x3, .scancode = sdl.SDL_SCANCODE_3 },
    .{ .chip_key = 0x4, .scancode = sdl.SDL_SCANCODE_Q },
    .{ .chip_key = 0x5, .scancode = sdl.SDL_SCANCODE_W },
    .{ .chip_key = 0x6, .scancode = sdl.SDL_SCANCODE_E },
    .{ .chip_key = 0x7, .scancode = sdl.SDL_SCANCODE_A },
    .{ .chip_key = 0x8, .scancode = sdl.SDL_SCANCODE_S },
    .{ .chip_key = 0x9, .scancode = sdl.SDL_SCANCODE_D },
    .{ .chip_key = 0xA, .scancode = sdl.SDL_SCANCODE_Z },
    .{ .chip_key = 0xB, .scancode = sdl.SDL_SCANCODE_C },
    .{ .chip_key = 0xC, .scancode = sdl.SDL_SCANCODE_4 },
    .{ .chip_key = 0xD, .scancode = sdl.SDL_SCANCODE_R },
    .{ .chip_key = 0xE, .scancode = sdl.SDL_SCANCODE_F },
    .{ .chip_key = 0xF, .scancode = sdl.SDL_SCANCODE_V },
};

fn chipKeyForScancode(scancode: c_uint) ?usize {
    for (key_bindings) |binding| {
        if (binding.scancode == scancode) return binding.chip_key;
    }
    return null;
}

fn check(ok: bool) !void {
    if (!ok) {
        std.log.err("SDL: {s}", .{sdl.SDL_GetError()});
        return error.SdlFailure;
    }
}

fn render(renderer: *sdl.SDL_Renderer, chip: *const Chip8) !void {
    try check(sdl.SDL_SetRenderDrawColor(renderer, 16, 22, 28, 255));
    try check(sdl.SDL_RenderClear(renderer));
    try check(sdl.SDL_SetRenderDrawColor(renderer, 151, 239, 183, 255));
    for (chip.display, 0..) |on, index| {
        if (!on) continue;
        const rect = sdl.SDL_FRect{ .x = @floatFromInt(index % 64), .y = @floatFromInt(index / 64), .w = 1, .h = 1 };
        try check(sdl.SDL_RenderFillRect(renderer, &rect));
    }
    try check(sdl.SDL_RenderPresent(renderer));
}

pub fn run(chip: *Chip8, rom: []const u8) !void {
    try check(sdl.SDL_Init(sdl.SDL_INIT_VIDEO | sdl.SDL_INIT_AUDIO));
    defer sdl.SDL_Quit();
    var window: ?*sdl.SDL_Window = null;
    var renderer: ?*sdl.SDL_Renderer = null;
    try check(sdl.SDL_CreateWindowAndRenderer("CHIP-8 | Space: pause | Backspace: reset", 960, 480, sdl.SDL_WINDOW_RESIZABLE, &window, &renderer));
    defer sdl.SDL_DestroyWindow(window);
    defer sdl.SDL_DestroyRenderer(renderer);
    try check(sdl.SDL_SetRenderLogicalPresentation(renderer, 64, 32, sdl.SDL_LOGICAL_PRESENTATION_INTEGER_SCALE));

    const spec = sdl.SDL_AudioSpec{ .format = sdl.SDL_AUDIO_F32, .channels = 1, .freq = 48000 };
    const audio = sdl.SDL_OpenAudioDeviceStream(sdl.SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, &spec, null, null);
    defer if (audio != null) sdl.SDL_DestroyAudioStream(audio);
    if (audio != null) {
        try check(sdl.SDL_ResumeAudioStreamDevice(audio));
    } else {
        std.log.warn("Audio unavailable: {s}", .{sdl.SDL_GetError()});
    }
    // A 20 ms chunk containing exactly eight periods of a 400 Hz tone.
    var tone: [960]f32 = undefined;
    for (&tone, 0..) |*sample, i| sample.* = if (i % 120 < 60) 0.12 else -0.12;

    var runtime = Runtime{};
    var paused = false;
    var focused = true;
    var previous = sdl.SDL_GetTicksNS();
    var next_frame = previous;
    while (true) {
        var event: sdl.SDL_Event = undefined;
        while (sdl.SDL_PollEvent(&event)) {
            switch (event.type) {
                sdl.SDL_EVENT_QUIT => return,
                sdl.SDL_EVENT_WINDOW_FOCUS_LOST => {
                    focused = false;
                    chip.keypad = [_]bool{false} ** 16;
                    chip.key_pressed = [_]bool{false} ** 16;
                },
                sdl.SDL_EVENT_WINDOW_FOCUS_GAINED => focused = true,
                sdl.SDL_EVENT_KEY_DOWN => {
                    if (event.key.repeat) continue;
                    if (chipKeyForScancode(event.key.scancode)) |key| chip.pressKey(key);
                    switch (event.key.scancode) {
                        sdl.SDL_SCANCODE_ESCAPE => return,
                        sdl.SDL_SCANCODE_SPACE => {
                            paused = !paused;
                            try check(sdl.SDL_SetWindowTitle(window, if (paused) "CHIP-8 | Paused | Space: resume" else "CHIP-8 | Space: pause | Backspace: reset"));
                        },
                        sdl.SDL_SCANCODE_BACKSPACE => {
                            chip.* = Chip8{};
                            try chip.loadRom(rom);
                            runtime = .{};
                        },
                        else => {},
                    }
                },
                else => {},
            }
        }
        const keyboard = sdl.SDL_GetKeyboardState(null);
        chip.keypad = [_]bool{false} ** 16;
        if (focused) {
            for (key_bindings) |binding| {
                if (keyboard[@intCast(binding.scancode)]) chip.keypad[binding.chip_key] = true;
            }
        }
        const now = sdl.SDL_GetTicksNS();
        const elapsed = @as(f64, @floatFromInt(now - previous)) / 1_000_000_000.0;
        previous = now;
        if (!paused and focused) runtime.advance(chip, elapsed);
        if (audio != null) {
            if (!paused and focused and chip.sound_timer > 0) {
                if (sdl.SDL_GetAudioStreamQueued(audio) < @sizeOf(@TypeOf(tone))) {
                    try check(sdl.SDL_PutAudioStreamData(audio, &tone, @sizeOf(@TypeOf(tone))));
                }
            } else try check(sdl.SDL_ClearAudioStream(audio));
        }
        if (now >= next_frame) {
            try render(renderer.?, chip);
            next_frame = now + 1_000_000_000 / 60;
        }
        sdl.SDL_Delay(1);
    }
}
