const std = @import("std");

const font_sprites = [_]u8{
    0xF0, 0x90, 0x90, 0x90, 0xF0, // 0
    0x20, 0x60, 0x20, 0x20, 0x70, // 1
    0xF0, 0x10, 0xF0, 0x80, 0xF0, // 2
    0xF0, 0x10, 0xF0, 0x10, 0xF0, // 3
    0x90, 0x90, 0xF0, 0x10, 0x10, // 4
    0xF0, 0x80, 0xF0, 0x10, 0xF0, // 5
    0xF0, 0x80, 0xF0, 0x90, 0xF0, // 6
    0xF0, 0x10, 0x20, 0x40, 0x40, // 7
    0xF0, 0x90, 0xF0, 0x90, 0xF0, // 8
    0xF0, 0x90, 0xF0, 0x10, 0xF0, // 9
    0xF0, 0x90, 0xF0, 0x90, 0x90, // A
    0xE0, 0x90, 0xE0, 0x90, 0xE0, // B
    0xF0, 0x80, 0x80, 0x80, 0xF0, // C
    0xE0, 0x90, 0x90, 0x90, 0xE0, // D
    0xF0, 0x80, 0xF0, 0x80, 0xF0, // E
    0xF0, 0x80, 0xF0, 0x80, 0x80, // F
};

fn initialMemory() [4096]u8 {
    var memory = [_]u8{0} ** 4096;
    for (font_sprites, 0..) |sprite, offset| {
        memory[0x50 + offset] = sprite;
    }
    return memory;
}

pub const Chip8 = struct {
    memory: [4096]u8 = initialMemory(),
    v: [16]u8 = [_]u8{0} ** 16,
    i: u16 = 0,
    pc: u16 = 0x200,
    halted: bool = false,

    stack: [16]u16 = [_]u16{0} ** 16,
    sp: u8 = 0,

    delay_timer: u8 = 0,
    sound_timer: u8 = 0,

    display: [64 * 32]bool = [_]bool{false} ** (64 * 32),
    keypad: [16]bool = [_]bool{false} ** 16,
    key_pressed: [16]bool = [_]bool{false} ** 16,

    rng: std.Random.DefaultPrng = std.Random.DefaultPrng.init(0),

    fn fetch(self: *Chip8) ?u16 {
        const pc: usize = self.pc;
        if (pc + 1 >= self.memory.len) {
            self.halted = true;
            return null;
        }

        const high: u16 = self.memory[pc];
        const low: u16 = self.memory[pc + 1];
        self.pc += 2;
        return (high << 8) | low;
    }

    pub fn loadRom(self: *Chip8, rom: []const u8) !void {
        const start: usize = 0x200;

        if (rom.len > self.memory.len - start) {
            return error.RomTooLarge;
        }

        for (rom, 0..) |byte, offset| {
            self.memory[start + offset] = byte;
        }

        self.pc = start;
    }

    /// Records a physical key-down event for the next CPU cycle.
    /// `keypad` continues to represent the keys currently held down.
    pub fn pressKey(self: *Chip8, key: usize) void {
        self.keypad[key] = true;
        self.key_pressed[key] = true;
    }

    /// 0NNN — `SYS address`: Calls an obsolete machine-code routine; ignored by this emulator.
    fn systemCall(self: *Chip8, address: u16) void {
        _ = self;
        _ = address;
    }

    /// 00E0 — `CLS`: Clears every pixel on the display.
    fn clearDisplay(self: *Chip8) void {
        self.display = [_]bool{false} ** (64 * 32);
    }

    /// 00EE — `RET`: Returns to the address saved by the current subroutine call.
    fn returnFromSubroutine(self: *Chip8) void {
        self.sp -= 1;
        self.pc = self.stack[self.sp];
    }

    /// 1NNN — `JP address`: Continues execution at an absolute address.
    fn jump(self: *Chip8, address: u16) void {
        self.pc = address;
    }

    /// 2NNN — `CALL address`: Enters a subroutine and saves the return address.
    fn callSubroutine(self: *Chip8, address: u16) void {
        self.stack[self.sp] = self.pc;
        self.sp += 1;
        self.pc = address;
    }

    /// 3XNN — `SE_BYTE Vx, byte`: Skips the next instruction when Vx equals a byte.
    fn skipIfEqual(self: *Chip8, x: u4, value: u8) void {
        if (self.v[x] == value) self.pc += 2;
    }

    /// 4XNN — `SNE_BYTE Vx, byte`: Skips the next instruction when Vx differs from a byte.
    fn skipIfNotEqual(self: *Chip8, x: u4, value: u8) void {
        if (self.v[x] != value) self.pc += 2;
    }

    /// 5XY0 — `SE_REG Vx, Vy`: Skips the next instruction when two registers are equal.
    fn skipIfRegistersEqual(self: *Chip8, x: u4, y: u4) void {
        if (self.v[x] == self.v[y]) self.pc += 2;
    }

    /// 6XNN — `LD_BYTE Vx, byte`: Stores a constant byte in Vx.
    fn loadImmediate(self: *Chip8, x: u4, value: u8) void {
        self.v[x] = value;
    }

    /// 7XNN — `ADD_BYTE Vx, byte`: Adds a constant byte to Vx with wrapping.
    fn addImmediate(self: *Chip8, x: u4, value: u8) void {
        self.v[x] +%= value;
    }

    /// 8XY0 — `LD_REG Vx, Vy`: Copies Vy into Vx.
    fn copyRegister(self: *Chip8, x: u4, y: u4) void {
        self.v[x] = self.v[y];
    }

    /// 8XY1 — `OR Vx, Vy`: Combines two registers with bitwise OR.
    fn orRegisters(self: *Chip8, x: u4, y: u4) void {
        self.v[x] |= self.v[y];
    }

    /// 8XY2 — `AND Vx, Vy`: Combines two registers with bitwise AND.
    fn andRegisters(self: *Chip8, x: u4, y: u4) void {
        self.v[x] &= self.v[y];
    }

    /// 8XY3 — `XOR Vx, Vy`: Combines two registers with bitwise XOR.
    fn xorRegisters(self: *Chip8, x: u4, y: u4) void {
        self.v[x] ^= self.v[y];
    }

    /// 8XY4 — `ADD_REG Vx, Vy`: Adds Vy to Vx and stores the carry in VF.
    fn addRegisters(self: *Chip8, x: u4, y: u4) void {
        const sum: u16 = @as(u16, self.v[x]) + @as(u16, self.v[y]);
        self.v[0xF] = if (sum > 0xFF) 1 else 0;
        self.v[x] = @truncate(sum);
    }

    /// 8XY5 — `SUB Vx, Vy`: Subtracts Vy from Vx and stores the no-borrow flag in VF.
    fn subtractRegisters(self: *Chip8, x: u4, y: u4) void {
        self.v[0xF] = if (self.v[x] >= self.v[y]) 1 else 0;
        self.v[x] -%= self.v[y];
    }

    /// 8XY6 — `SHR Vx`: Shifts Vx right and stores the removed bit in VF.
    fn shiftRight(self: *Chip8, x: u4) void {
        self.v[0xF] = self.v[x] & 1;
        self.v[x] >>= 1;
    }

    /// 8XY7 — `SUBN Vx, Vy`: Sets Vx to Vy minus Vx and stores the no-borrow flag in VF.
    fn reverseSubtractRegisters(self: *Chip8, x: u4, y: u4) void {
        self.v[0xF] = if (self.v[y] >= self.v[x]) 1 else 0;
        self.v[x] = self.v[y] -% self.v[x];
    }

    /// 8XYE — `SHL Vx`: Shifts Vx left and stores the removed bit in VF.
    fn shiftLeft(self: *Chip8, x: u4) void {
        self.v[0xF] = (self.v[x] >> 7) & 1;
        self.v[x] <<= 1;
    }

    /// 9XY0 — `SNE_REG Vx, Vy`: Skips the next instruction when two registers differ.
    fn skipIfRegistersNotEqual(self: *Chip8, x: u4, y: u4) void {
        if (self.v[x] != self.v[y]) self.pc += 2;
    }

    /// ANNN — `LD_I address`: Points I at data or code in CHIP-8 memory.
    fn loadIndex(self: *Chip8, address: u16) void {
        self.i = address;
    }

    /// BNNN — `JP_V0 address`: Jumps to an address plus the value in V0.
    fn jumpWithOffset(self: *Chip8, address: u16) void {
        self.pc = address + self.v[0];
    }

    /// CXNN — `RND Vx, mask`: Stores a random byte ANDed with a mask in Vx.
    fn randomMasked(self: *Chip8, x: u4, mask: u8) void {
        self.v[x] = self.rng.random().int(u8) & mask;
    }

    /// EX9E — `SKP Vx`: Skips the next instruction when the key named by Vx is held.
    fn skipIfKeyPressed(self: *Chip8, x: u4) void {
        if (self.keypad[self.v[x]]) self.pc += 2;
    }

    /// EXA1 — `SKNP Vx`: Skips the next instruction when the key named by Vx is not held.
    fn skipIfKeyNotPressed(self: *Chip8, x: u4) void {
        if (!self.keypad[self.v[x]]) self.pc += 2;
    }

    /// FX07 — `GET_DT Vx`: Copies the current delay timer value into Vx.
    fn readDelayTimer(self: *Chip8, x: u4) void {
        self.v[x] = self.delay_timer;
    }

    /// FX15 — `SET_DT Vx`: Starts or changes the delay timer using Vx.
    fn setDelayTimer(self: *Chip8, x: u4) void {
        self.delay_timer = self.v[x];
    }

    /// FX18 — `SET_ST Vx`: Starts or changes the sound timer using Vx.
    fn setSoundTimer(self: *Chip8, x: u4) void {
        self.sound_timer = self.v[x];
    }

    /// FX1E — `ADD_I Vx`: Advances the I address by the value in Vx.
    fn addToIndex(self: *Chip8, x: u4) void {
        self.i +%= self.v[x];
    }

    /// FX29 — `LD_FONT Vx`: Points I at the built-in glyph for the digit in Vx.
    fn loadFontAddress(self: *Chip8, x: u4) void {
        self.i = 0x50 + (@as(u16, self.v[x]) * 5);
    }

    /// FX33 — `BCD Vx`: Writes the three decimal digits of Vx to memory at I.
    fn storeDecimalDigits(self: *Chip8, x: u4) void {
        self.memory[self.i] = self.v[x] / 100;
        self.memory[self.i + 1] = (self.v[x] / 10) % 10;
        self.memory[self.i + 2] = self.v[x] % 10;
    }

    /// FX55 — `STORE Vx`: Writes registers V0 through Vx to memory starting at I.
    fn storeRegisters(self: *Chip8, x: u4) void {
        for (0..@as(usize, x) + 1) |register| {
            self.memory[self.i + register] = self.v[register];
        }
    }

    /// FX65 — `LOAD Vx`: Reads registers V0 through Vx from memory starting at I.
    fn loadRegisters(self: *Chip8, x: u4) void {
        for (0..@as(usize, x) + 1) |register| {
            self.v[register] = self.memory[self.i + register];
        }
    }

    /// DXYN — `DRW Vx, Vy, height`: XOR-draws an 8-pixel-wide sprite and reports collisions in VF.
    fn drawSprite(self: *Chip8, x_register: u4, y_register: u4, height: u4) void {
        self.v[0xF] = 0;

        for (0..height) |row| {
            const sprite = self.memory[self.i + row];

            for (0..8) |column| {
                const sprite_pixel = (sprite >> @intCast(7 - column)) & 1;

                if (sprite_pixel == 1) {
                    const x = (@as(usize, self.v[x_register]) + column) % 64;
                    const y = (@as(usize, self.v[y_register]) + row) % 32;
                    const display_index = y * 64 + x;

                    if (self.display[display_index]) {
                        self.v[0xF] = 1;
                    }

                    self.display[display_index] = !self.display[display_index];
                }
            }
        }
    }

    /// FX0A — `WAIT_KEY Vx`: Pauses on this instruction until a new key press can be stored in Vx.
    fn waitForKey(self: *Chip8, register: u4) void {
        for (self.key_pressed, 0..) |pressed, key| {
            if (pressed) {
                self.v[register] = @intCast(key);
                return;
            }
        }
        self.pc -= 2;
    }

    pub fn tickTimers(self: *Chip8) void {
        if (self.delay_timer > 0) {
            self.delay_timer -= 1;
        }

        if (self.sound_timer > 0) {
            self.sound_timer -= 1;
        }
    }

    pub fn cycle(self: *Chip8) void {
        defer self.key_pressed = [_]bool{false} ** 16;
        const opcode = self.fetch() orelse return;
        const x: u4 = @truncate(opcode >> 8);
        const y: u4 = @truncate(opcode >> 4);
        const nnn = opcode & 0x0FFF;
        const nn: u8 = @truncate(opcode);
        const n: u4 = @truncate(opcode);

        switch (opcode & 0xF000) {
            0x0000 => switch (opcode) {
                0x00E0 => self.clearDisplay(),
                0x00EE => self.returnFromSubroutine(),
                else => self.systemCall(nnn),
            },
            0x1000 => self.jump(nnn),
            0x2000 => self.callSubroutine(nnn),
            0x3000 => self.skipIfEqual(x, nn),
            0x4000 => self.skipIfNotEqual(x, nn),
            0x5000 => if (n == 0) self.skipIfRegistersEqual(x, y),
            0x6000 => self.loadImmediate(x, nn),
            0x7000 => self.addImmediate(x, nn),
            0x8000 => switch (n) {
                0x0 => self.copyRegister(x, y),
                0x1 => self.orRegisters(x, y),
                0x2 => self.andRegisters(x, y),
                0x3 => self.xorRegisters(x, y),
                0x4 => self.addRegisters(x, y),
                0x5 => self.subtractRegisters(x, y),
                0x6 => self.shiftRight(x),
                0x7 => self.reverseSubtractRegisters(x, y),
                0xE => self.shiftLeft(x),
                else => {},
            },
            0x9000 => if (n == 0) self.skipIfRegistersNotEqual(x, y),
            0xA000 => self.loadIndex(nnn),
            0xB000 => self.jumpWithOffset(nnn),
            0xC000 => self.randomMasked(x, nn),
            0xD000 => self.drawSprite(x, y, n),
            0xE000 => switch (nn) {
                0x9E => self.skipIfKeyPressed(x),
                0xA1 => self.skipIfKeyNotPressed(x),
                else => {},
            },
            0xF000 => switch (nn) {
                0x07 => self.readDelayTimer(x),
                0x0A => self.waitForKey(x),
                0x15 => self.setDelayTimer(x),
                0x18 => self.setSoundTimer(x),
                0x1E => self.addToIndex(x),
                0x29 => self.loadFontAddress(x),
                0x33 => self.storeDecimalDigits(x),
                0x55 => self.storeRegisters(x),
                0x65 => self.loadRegisters(x),
                else => {},
            },
            else => {},
        }
    }
};

test "set and add register" {
    var chip8 = Chip8{
        .rng = std.Random.DefaultPrng.init(0),
    };

    chip8.memory[0x200] = 0x60;
    chip8.memory[0x201] = 0x05;
    chip8.memory[0x202] = 0x70;
    chip8.memory[0x203] = 0x03;

    chip8.cycle();
    try std.testing.expectEqual(@as(u8, 5), chip8.v[0]);

    chip8.cycle();
    try std.testing.expectEqual(@as(u8, 8), chip8.v[0]);
}

test "draw sprite" {
    var chip8 = Chip8{};

    chip8.i = 0x300;
    chip8.v[0] = 2;
    chip8.v[1] = 3;

    // Draw one pixel at the first sprite position.
    chip8.memory[0x300] = 0b10000000;

    // D011: draw sprite at V0, V1 with height 1.
    chip8.memory[0x200] = 0xD0;
    chip8.memory[0x201] = 0x11;

    chip8.cycle();

    try std.testing.expect(chip8.display[3 * 64 + 2]);
    try std.testing.expectEqual(@as(u8, 0), chip8.v[0xF]);

    // Drawing the same sprite again erases the pixel.
    chip8.pc = 0x200;
    chip8.cycle();

    try std.testing.expect(!chip8.display[3 * 64 + 2]);
    try std.testing.expectEqual(@as(u8, 1), chip8.v[0xF]);
}

test "conditional skips" {
    var chip8 = Chip8{};

    chip8.v[0] = 5;
    chip8.v[1] = 5;

    // 3005: skip because V0 == 5
    chip8.memory[0x200] = 0x30;
    chip8.memory[0x201] = 0x05;

    chip8.cycle();

    try std.testing.expectEqual(@as(u16, 0x204), chip8.pc);

    chip8.pc = 0x200;

    // 5000: skip because V0 == V1
    chip8.memory[0x200] = 0x50;
    chip8.memory[0x201] = 0x10;

    chip8.cycle();

    try std.testing.expectEqual(@as(u16, 0x204), chip8.pc);
}

test "8XY4 adds registers and sets carry" {
    var chip8 = Chip8{};

    chip8.v[1] = 250;
    chip8.v[2] = 10;

    // 8124: V1 = V1 + V2
    chip8.memory[0x200] = 0x81;
    chip8.memory[0x201] = 0x24;

    chip8.cycle();

    try std.testing.expectEqual(@as(u8, 4), chip8.v[1]);
    try std.testing.expectEqual(@as(u8, 1), chip8.v[0xF]);
}

test "skip when registers differ" {
    var chip8 = Chip8{};

    chip8.v[1] = 5;
    chip8.v[2] = 7;

    // 9120: skip if V1 != V2
    chip8.memory[0x200] = 0x91;
    chip8.memory[0x201] = 0x20;

    chip8.cycle();

    try std.testing.expectEqual(@as(u16, 0x204), chip8.pc);
}

test "timers tick at zero instead of underflowing" {
    var chip8 = Chip8{
        .delay_timer = 2,
        .sound_timer = 1,
    };

    chip8.tickTimers();
    try std.testing.expectEqual(@as(u8, 1), chip8.delay_timer);
    try std.testing.expectEqual(@as(u8, 0), chip8.sound_timer);

    chip8.tickTimers();
    try std.testing.expectEqual(@as(u8, 0), chip8.delay_timer);
    try std.testing.expectEqual(@as(u8, 0), chip8.sound_timer);
}

test "load ROM at program start" {
    var chip8 = Chip8{};
    const rom = [_]u8{ 0x60, 0x05, 0x70, 0x03 };

    try chip8.loadRom(&rom);

    try std.testing.expectEqual(@as(u16, 0x200), chip8.pc);
    try std.testing.expectEqual(@as(u8, 0x60), chip8.memory[0x200]);
    try std.testing.expectEqual(@as(u8, 0x05), chip8.memory[0x201]);
    try std.testing.expectEqual(@as(u8, 0x70), chip8.memory[0x202]);
    try std.testing.expectEqual(@as(u8, 0x03), chip8.memory[0x203]);
}

test "font and FX memory instructions" {
    var chip8 = Chip8{};

    try std.testing.expectEqual(@as(u8, 0xF0), chip8.memory[0x50]);
    try std.testing.expectEqual(@as(u8, 0xF0), chip8.memory[0x50 + 9 * 5]);

    chip8.v[0] = 9;
    chip8.v[1] = 8;
    chip8.v[2] = 7;
    chip8.i = 0x300;

    // F233: store the BCD digits of V2 at I, I+1, and I+2.
    chip8.memory[0x200] = 0xF2;
    chip8.memory[0x201] = 0x33;
    chip8.v[2] = 237;
    chip8.cycle();

    try std.testing.expectEqual(@as(u8, 2), chip8.memory[0x300]);
    try std.testing.expectEqual(@as(u8, 3), chip8.memory[0x301]);
    try std.testing.expectEqual(@as(u8, 7), chip8.memory[0x302]);

    // F155: store V0 and V1, then F165 loads them back.
    chip8.v[0] = 0xAB;
    chip8.v[1] = 0xCD;
    chip8.memory[0x202] = 0xF1;
    chip8.memory[0x203] = 0x55;
    chip8.cycle();

    chip8.v[0] = 0;
    chip8.v[1] = 0;
    chip8.memory[0x204] = 0xF1;
    chip8.memory[0x205] = 0x65;
    chip8.cycle();

    try std.testing.expectEqual(@as(u8, 0xAB), chip8.v[0]);
    try std.testing.expectEqual(@as(u8, 0xCD), chip8.v[1]);
}

test "FX1E and FX29 update the index register" {
    var chip8 = Chip8{};
    chip8.i = 0x300;
    chip8.v[2] = 0x10;

    // F21E: I += V2.
    chip8.memory[0x200] = 0xF2;
    chip8.memory[0x201] = 0x1E;
    chip8.cycle();
    try std.testing.expectEqual(@as(u16, 0x310), chip8.i);

    // F229: I points to the 2 sprite, which starts at 0x5A.
    chip8.v[2] = 2;
    chip8.memory[0x202] = 0xF2;
    chip8.memory[0x203] = 0x29;
    chip8.cycle();
    try std.testing.expectEqual(@as(u16, 0x5A), chip8.i);
}

test "FX0A resumes on a key press without waiting for release" {
    var chip = Chip8{};
    try chip.loadRom(&.{ 0xF2, 0x0A, 0xF3, 0x0A });

    chip.cycle();
    try std.testing.expectEqual(@as(u16, 0x200), chip.pc);

    chip.pressKey(0xC);
    chip.cycle();
    try std.testing.expectEqual(@as(u8, 0xC), chip.v[2]);
    try std.testing.expectEqual(@as(u16, 0x202), chip.pc);
    try std.testing.expect(chip.keypad[0xC]);

    // Holding the key cannot satisfy a second wait instruction.
    chip.cycle();
    try std.testing.expectEqual(@as(u16, 0x202), chip.pc);

    chip.keypad[0xC] = false;
    chip.pressKey(0xA);
    chip.cycle();
    try std.testing.expectEqual(@as(u8, 0xA), chip.v[3]);
    try std.testing.expectEqual(@as(u16, 0x204), chip.pc);
}

test "FX0A does not consume presses from earlier instructions" {
    var chip = Chip8{};
    try chip.loadRom(&.{ 0x60, 0x00, 0xF2, 0x0A });

    chip.pressKey(0xC);
    chip.cycle();
    chip.cycle();
    try std.testing.expectEqual(@as(u16, 0x202), chip.pc);
    try std.testing.expectEqual(@as(u8, 0), chip.v[2]);
}
