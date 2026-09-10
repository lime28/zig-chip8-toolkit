const std = @import("std");
const program_start = 0x200;
const max_instructions = 0xE00 / 2;
const max_work_items = max_instructions * 2;

fn enqueue(queue: *[max_work_items]u16, tail: *usize, address: u16) void {
    if (tail.* == queue.len) return;
    queue[tail.*] = address;
    tail.* += 1;
}

/// Mark instructions reachable from 0x200. This prevents sprite and other data
/// following the program from being presented as executable opcodes.
fn reachableInstructions(rom: []const u8) [max_instructions]bool {
    var reachable = [_]bool{false} ** max_instructions;
    var queue: [max_work_items]u16 = undefined;
    var head: usize = 0;
    var tail: usize = 0;
    enqueue(&queue, &tail, program_start);

    while (head < tail) {
        const address = queue[head];
        head += 1;
        if (address < program_start or address + 1 >= program_start + rom.len or address % 2 != 0) continue;
        const index = (address - program_start) / 2;
        if (reachable[index]) continue;
        reachable[index] = true;

        const offset: usize = index * 2;
        const opcode = (@as(u16, rom[offset]) << 8) | rom[offset + 1];
        const next = address +| 2;
        switch (opcode & 0xF000) {
            0x0000 => if (opcode != 0x00EE) enqueue(&queue, &tail, next),
            0x1000 => enqueue(&queue, &tail, opcode & 0x0FFF),
            0x2000 => {
                enqueue(&queue, &tail, opcode & 0x0FFF);
                enqueue(&queue, &tail, next);
            },
            0x3000, 0x4000, 0x5000, 0x9000, 0xE000 => {
                enqueue(&queue, &tail, next);
                enqueue(&queue, &tail, next +| 2);
            },
            0xB000 => {}, // The target depends on V0 and cannot be known statically.
            else => enqueue(&queue, &tail, next),
        }
    }
    return reachable;
}

fn printOpcode(address: u16, opcode: u16) void {
    const x: u4 = @truncate(opcode >> 8);
    const y: u4 = @truncate(opcode >> 4);
    const nnn = opcode & 0x0FFF;
    const nn: u8 = @truncate(opcode);
    const n: u4 = @truncate(opcode);

    std.debug.print("{X:0>3}  {X:0>4}  ", .{ address, opcode });
    switch (opcode & 0xF000) {
        0x0000 => switch (opcode) {
            0x00E0 => std.debug.print("CLS", .{}),
            0x00EE => std.debug.print("RET", .{}),
            else => std.debug.print("SYS 0x{X:0>3}", .{nnn}),
        },
        0x1000 => std.debug.print("JP 0x{X:0>3}", .{nnn}),
        0x2000 => std.debug.print("CALL 0x{X:0>3}", .{nnn}),
        0x3000 => std.debug.print("SE_BYTE V{X}, 0x{X:0>2}", .{ x, nn }),
        0x4000 => std.debug.print("SNE_BYTE V{X}, 0x{X:0>2}", .{ x, nn }),
        0x5000 => if (n == 0) std.debug.print("SE_REG V{X}, V{X}", .{ x, y }) else std.debug.print("DATA 0x{X:0>4}", .{opcode}),
        0x6000 => std.debug.print("LD_BYTE V{X}, 0x{X:0>2}", .{ x, nn }),
        0x7000 => std.debug.print("ADD_BYTE V{X}, 0x{X:0>2}", .{ x, nn }),
        0x8000 => switch (n) {
            0x0 => std.debug.print("LD_REG V{X}, V{X}", .{ x, y }),
            0x1 => std.debug.print("OR V{X}, V{X}", .{ x, y }),
            0x2 => std.debug.print("AND V{X}, V{X}", .{ x, y }),
            0x3 => std.debug.print("XOR V{X}, V{X}", .{ x, y }),
            0x4 => std.debug.print("ADD_REG V{X}, V{X}", .{ x, y }),
            0x5 => std.debug.print("SUB V{X}, V{X}", .{ x, y }),
            0x6 => std.debug.print("SHR V{X}", .{x}),
            0x7 => std.debug.print("SUBN V{X}, V{X}", .{ x, y }),
            0xE => std.debug.print("SHL V{X}", .{x}),
            else => std.debug.print("DATA 0x{X:0>4}", .{opcode}),
        },
        0x9000 => if (n == 0) std.debug.print("SNE_REG V{X}, V{X}", .{ x, y }) else std.debug.print("DATA 0x{X:0>4}", .{opcode}),
        0xA000 => std.debug.print("LD_I 0x{X:0>3}", .{nnn}),
        0xB000 => std.debug.print("JP_V0 0x{X:0>3}", .{nnn}),
        0xC000 => std.debug.print("RND V{X}, 0x{X:0>2}", .{ x, nn }),
        0xD000 => std.debug.print("DRW V{X}, V{X}, 0x{X}", .{ x, y, n }),
        0xE000 => switch (nn) {
            0x9E => std.debug.print("SKP V{X}", .{x}),
            0xA1 => std.debug.print("SKNP V{X}", .{x}),
            else => std.debug.print("DATA 0x{X:0>4}", .{opcode}),
        },
        0xF000 => switch (nn) {
            0x07 => std.debug.print("GET_DT V{X}", .{x}),
            0x0A => std.debug.print("WAIT_KEY V{X}", .{x}),
            0x15 => std.debug.print("SET_DT V{X}", .{x}),
            0x18 => std.debug.print("SET_ST V{X}", .{x}),
            0x1E => std.debug.print("ADD_I V{X}", .{x}),
            0x29 => std.debug.print("LD_FONT V{X}", .{x}),
            0x33 => std.debug.print("BCD V{X}", .{x}),
            0x55 => std.debug.print("STORE V{X}", .{x}),
            0x65 => std.debug.print("LOAD V{X}", .{x}),
            else => std.debug.print("DATA 0x{X:0>4}", .{opcode}),
        },
        else => unreachable,
    }
    std.debug.print("\n", .{});
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 2 or std.mem.eql(u8, args[1], "--help")) {
        std.debug.print("Usage: {s} <rom.ch8>\n", .{args[0]});
        return;
    }

    const rom = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        args[1],
        allocator,
        std.Io.Limit.limited(0xE00),
    );
    const reachable = reachableInstructions(rom);
    var offset: usize = 0;
    while (offset + 1 < rom.len) : (offset += 2) {
        const opcode = (@as(u16, rom[offset]) << 8) | rom[offset + 1];
        const address: u16 = @intCast(program_start + offset);
        if (reachable[offset / 2]) {
            printOpcode(address, opcode);
        } else {
            std.debug.print("{X:0>3}  {X:0>4}  DATA 0x{X:0>4}\n", .{ address, opcode, opcode });
        }
    }
    if (offset < rom.len) std.debug.print("{X:0>3}  {X:0>2}    .byte 0x{X:0>2}  ; trailing byte\n", .{ program_start + offset, rom[offset], rom[offset] });
}
