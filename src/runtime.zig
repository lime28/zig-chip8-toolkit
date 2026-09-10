const std = @import("std");
const Chip8 = @import("chip8.zig").Chip8;

/// CPU and timer clocks are independent of rendering and event polling.
pub const Runtime = struct {
    const cpu_period: f64 = 1.0 / 700.0;
    const timer_period: f64 = 1.0 / 60.0;
    cpu_remaining: f64 = cpu_period,
    timer_remaining: f64 = timer_period,

    pub fn advance(self: *Runtime, chip: *Chip8, elapsed: f64) void {
        // Avoid a runaway catch-up loop after a debugger stop or window drag.
        var remaining = std.math.clamp(elapsed, 0, 0.1);
        while (remaining > 0) {
            const step = @min(remaining, @min(self.cpu_remaining, self.timer_remaining));
            remaining -= step;
            self.cpu_remaining -= step;
            self.timer_remaining -= step;
            if (self.timer_remaining <= 0) {
                chip.tickTimers();
                self.timer_remaining += timer_period;
            }
            if (!chip.halted and self.cpu_remaining <= 0) {
                chip.cycle();
                self.cpu_remaining += cpu_period;
            }
        }
    }
};

test "timers continue while the CPU waits for input" {
    var chip = Chip8{ .delay_timer = 60 };
    try chip.loadRom(&.{ 0xF0, 0x0A, 0x12, 0x02 });
    var runtime = Runtime{};
    for (0..1000) |_| runtime.advance(&chip, 0.001);
    try std.testing.expect(chip.delay_timer <= 1);
    try std.testing.expectEqual(@as(u16, 0x200), chip.pc);
    chip.pressKey(0xA);
    runtime.advance(&chip, 0.002);
    try std.testing.expectEqual(@as(u8, 0xA), chip.v[0]);
    try std.testing.expectEqual(@as(u16, 0x202), chip.pc);
    try std.testing.expect(chip.keypad[0xA]);
}

test "execution halts safely at the end of memory" {
    var chip = Chip8{ .pc = 0x0FFF };
    chip.cycle();
    try std.testing.expect(chip.halted);
    try std.testing.expectEqual(@as(u16, 0x0FFF), chip.pc);
}

test "CPU runs at 700 Hz independently of timer ticks" {
    var chip = Chip8{ .delay_timer = 10 };
    try chip.loadRom(&.{ 0x70, 0x01, 0x12, 0x00 });
    var runtime = Runtime{};
    for (0..100) |_| runtime.advance(&chip, 0.001);
    try std.testing.expect(chip.v[0] >= 34 and chip.v[0] <= 35);
    try std.testing.expect(chip.delay_timer >= 4 and chip.delay_timer <= 5);
}
