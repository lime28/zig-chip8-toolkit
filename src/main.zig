const std = @import("std");
const Chip8 = @import("chip8.zig").Chip8;
const frontend = @import("frontend.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 2 or std.mem.eql(u8, args[1], "--help")) {
        std.debug.print("Usage: {s} <rom.ch8>\nKeys: 1234 / QWER / ASDF / ZXCV | Space: pause | Backspace: reset | Escape: quit\n", .{args[0]});
        if (args.len == 2) return;
        return error.MissingRomPath;
    }
    const rom = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        args[1],
        allocator,
        std.Io.Limit.limited(0xE00),
    );
    if (rom.len == 0) return error.EmptyRom;
    if (std.mem.startsWith(u8, rom, "#")) {
        std.debug.print(
            "{s} is Octo source code, not a compiled CHIP-8 ROM. Compile it to a .ch8 file first.\n",
            .{args[1]},
        );
        return error.OctoSourceFile;
    }
    var chip8 = Chip8{};
    try chip8.loadRom(rom);
    try frontend.run(&chip8, rom);
}
