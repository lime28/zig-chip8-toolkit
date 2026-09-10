const std = @import("std");
const Allocator = std.mem.Allocator;
const Labels = std.StringHashMap(u16);
const program_start = 0x200;
const max_rom_size = 0xE00;

fn equal(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn trim(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, " \t\r");
}

fn validLabel(name: []const u8) bool {
    if (name.len == 0 or (!std.ascii.isAlphabetic(name[0]) and name[0] != '_')) return false;
    for (name[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    return true;
}

const Line = struct {
    label: ?[]const u8,
    mnemonic: []const u8,
    operands: []const u8,

    fn parse(raw: []const u8) !Line {
        var text = trim(raw[0 .. std.mem.indexOfScalar(u8, raw, ';') orelse raw.len]);
        var label: ?[]const u8 = null;
        if (std.mem.indexOfScalar(u8, text, ':')) |colon| {
            label = trim(text[0..colon]);
            if (!validLabel(label.?)) return error.InvalidLabel;
            text = trim(text[colon + 1 ..]);
        }
        const end = std.mem.indexOfAny(u8, text, " \t") orelse text.len;
        return .{ .label = label, .mnemonic = text[0..end], .operands = trim(text[end..]) };
    }
};

fn register(text: []const u8) ?u16 {
    if (text.len != 2 or std.ascii.toUpper(text[0]) != 'V') return null;
    return std.fmt.parseInt(u16, text[1..], 16) catch null;
}

fn registerOperand(text: []const u8) !u16 {
    return register(text) orelse error.ExpectedRegister;
}

fn value(text: []const u8, labels: *const Labels, maximum: u16) !u16 {
    const result = labels.get(text) orelse (std.fmt.parseInt(u16, text, 0) catch {
        if (validLabel(text)) return error.UnknownLabel;
        return error.InvalidNumber;
    });
    if (result > maximum) return error.ValueOutOfRange;
    return result;
}

const Operands = struct {
    items: [3][]const u8 = undefined,
    len: usize = 0,

    fn parse(text: []const u8) !Operands {
        var result = Operands{};
        if (text.len == 0) return result;
        var parts = std.mem.splitScalar(u8, text, ',');
        while (parts.next()) |part| {
            if (result.len == result.items.len) return error.WrongOperandCount;
            const operand = trim(part);
            if (operand.len == 0) return error.EmptyOperand;
            result.items[result.len] = operand;
            result.len += 1;
        }
        return result;
    }

    fn expect(self: Operands, count: usize) !void {
        if (self.len != count) return error.WrongOperandCount;
    }
};

fn encode(line: Line, labels: *const Labels) !u16 {
    const op = line.mnemonic;
    const args = try Operands.parse(line.operands);

    if (equal(op, "CLS") or equal(op, "RET")) {
        try args.expect(0);
        return if (equal(op, "CLS")) 0x00E0 else 0x00EE;
    }

    if (equal(op, "SYS") or equal(op, "CALL") or equal(op, "DATA")) {
        try args.expect(1);
        const base: u16 = if (equal(op, "CALL")) 0x2000 else 0;
        return base | try value(args.items[0], labels, if (equal(op, "DATA")) 0xFFFF else 0xFFF);
    }

    if (equal(op, "JP")) {
        try args.expect(1);
        return 0x1000 | try value(args.items[0], labels, 0xFFF);
    }

    if (equal(op, "JP_V0")) {
        try args.expect(1);
        return 0xB000 | try value(args.items[0], labels, 0xFFF);
    }

    if (equal(op, "SHR") or equal(op, "SHL") or equal(op, "SKP") or equal(op, "SKNP")) {
        try args.expect(1);
        const base: u16 = if (equal(op, "SHR")) 0x8006 else if (equal(op, "SHL")) 0x800E else if (equal(op, "SKP")) 0xE09E else 0xE0A1;
        return base | ((try registerOperand(args.items[0])) << 8);
    }

    if (equal(op, "DRW")) {
        try args.expect(3);
        return 0xD000 | ((try registerOperand(args.items[0])) << 8) |
            ((try registerOperand(args.items[1])) << 4) | try value(args.items[2], labels, 0xF);
    }

    if (equal(op, "SE_BYTE") or equal(op, "SNE_BYTE")) {
        try args.expect(2);
        const base: u16 = if (equal(op, "SE_BYTE")) 0x3000 else 0x4000;
        return base | ((try registerOperand(args.items[0])) << 8) | try value(args.items[1], labels, 0xFF);
    }

    if (equal(op, "SE_REG") or equal(op, "SNE_REG")) {
        try args.expect(2);
        const base: u16 = if (equal(op, "SE_REG")) 0x5000 else 0x9000;
        return base | ((try registerOperand(args.items[0])) << 8) | ((try registerOperand(args.items[1])) << 4);
    }

    if (equal(op, "LD_BYTE") or equal(op, "ADD_BYTE")) {
        try args.expect(2);
        const base: u16 = if (equal(op, "LD_BYTE")) 0x6000 else 0x7000;
        return base | ((try registerOperand(args.items[0])) << 8) | try value(args.items[1], labels, 0xFF);
    }

    if (equal(op, "LD_I")) {
        try args.expect(1);
        return 0xA000 | try value(args.items[0], labels, 0xFFF);
    }

    if (equal(op, "RND")) {
        try args.expect(2);
        return 0xC000 | ((try registerOperand(args.items[0])) << 8) | try value(args.items[1], labels, 0xFF);
    }

    if (equal(op, "GET_DT") or equal(op, "WAIT_KEY") or equal(op, "SET_DT") or
        equal(op, "SET_ST") or equal(op, "ADD_I") or equal(op, "LD_FONT") or
        equal(op, "BCD") or equal(op, "STORE") or equal(op, "LOAD"))
    {
        try args.expect(1);
        const base: u16 = if (equal(op, "GET_DT")) 0xF007 else if (equal(op, "WAIT_KEY")) 0xF00A else if (equal(op, "SET_DT")) 0xF015 else if (equal(op, "SET_ST")) 0xF018 else if (equal(op, "ADD_I")) 0xF01E else if (equal(op, "LD_FONT")) 0xF029 else if (equal(op, "BCD")) 0xF033 else if (equal(op, "STORE")) 0xF055 else 0xF065;
        return base | ((try registerOperand(args.items[0])) << 8);
    }

    const base: u16 = if (equal(op, "LD_REG")) 0x8000 else if (equal(op, "OR")) 0x8001 else if (equal(op, "AND")) 0x8002 else if (equal(op, "XOR")) 0x8003 else if (equal(op, "ADD_REG")) 0x8004 else if (equal(op, "SUB")) 0x8005 else if (equal(op, "SUBN")) 0x8007 else return error.UnknownInstruction;
    try args.expect(2);
    return base | ((try registerOperand(args.items[0])) << 8) | ((try registerOperand(args.items[1])) << 4);
}

fn byteCount(text: []const u8) !usize {
    var parts = std.mem.splitScalar(u8, text, ',');
    var count: usize = 0;
    while (parts.next()) |part| {
        if (trim(part).len == 0) return error.EmptyOperand;
        count += 1;
    }
    return count;
}

fn assemble(allocator: Allocator, source: []const u8, error_line: *usize) ![]u8 {
    var labels = Labels.init(allocator);
    defer labels.deinit();
    var size: usize = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    error_line.* = 0;
    while (lines.next()) |raw| {
        error_line.* += 1;
        const line = try Line.parse(raw);
        if (line.label) |label| {
            const entry = try labels.getOrPut(label);
            if (entry.found_existing) return error.DuplicateLabel;
            entry.value_ptr.* = @intCast(program_start + size);
        }
        if (line.mnemonic.len == 0) continue;
        const is_byte = equal(line.mnemonic, ".byte");
        if (!is_byte and !equal(line.mnemonic, "DATA") and size % 2 != 0) return error.UnalignedInstruction;
        size += if (is_byte) try byteCount(line.operands) else 2;
        if (size > max_rom_size) return error.RomTooLarge;
    }
    if (size == 0) return error.EmptyProgram;

    const rom = try allocator.alloc(u8, size);
    errdefer allocator.free(rom);
    var offset: usize = 0;
    lines.reset();
    error_line.* = 0;
    while (lines.next()) |raw| {
        error_line.* += 1;
        const line = try Line.parse(raw);
        if (line.mnemonic.len == 0) continue;
        if (equal(line.mnemonic, ".byte")) {
            var parts = std.mem.splitScalar(u8, line.operands, ',');
            while (parts.next()) |part| {
                rom[offset] = @intCast(try value(trim(part), &labels, 0xFF));
                offset += 1;
            }
        } else {
            const opcode = try encode(line, &labels);
            rom[offset] = @intCast(opcode >> 8);
            rom[offset + 1] = @truncate(opcode);
            offset += 2;
        }
    }
    return rom;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len == 2 and equal(args[1], "--help")) {
        std.debug.print("Usage: {s} <programs/name.asm>\nWrites roms/name.ch8\n", .{args[0]});
        return;
    }
    if (args.len != 2) {
        std.debug.print("Usage: {s} <programs/name.asm>\n", .{args[0]});
        std.process.exit(1);
    }
    const cwd = std.Io.Dir.cwd();
    const source = cwd.readFileAlloc(init.io, args[1], allocator, .limited(1024 * 1024)) catch |err| {
        std.debug.print("{s}: {s}\n", .{ args[1], @errorName(err) });
        std.process.exit(1);
    };
    var error_line: usize = 0;
    const rom = assemble(allocator, source, &error_line) catch |err| {
        std.debug.print("{s}:{d}: {s}\n", .{ args[1], error_line, @errorName(err) });
        std.process.exit(1);
    };
    const stem = std.fs.path.stem(args[1]);
    if (stem.len == 0) return error.InvalidFilename;
    const output = try std.fmt.allocPrint(allocator, "roms/{s}.ch8", .{stem});
    try cwd.createDirPath(init.io, "roms");
    try cwd.writeFile(init.io, .{ .sub_path = output, .data = rom });
    std.debug.print("{s}: {d} bytes\n", .{ output, rom.len });
}

test "encode every supported instruction form" {
    const Case = struct { source: []const u8, opcode: u16 };
    const cases = [_]Case{
        .{ .source = "CLS", .opcode = 0x00E0 },
        .{ .source = "RET", .opcode = 0x00EE },
        .{ .source = "SYS 0x123", .opcode = 0x0123 },
        .{ .source = "JP 0x234", .opcode = 0x1234 },
        .{ .source = "CALL 0x345", .opcode = 0x2345 },
        .{ .source = "SE_BYTE V2, 0xAB", .opcode = 0x32AB },
        .{ .source = "SNE_BYTE V2, 0xAB", .opcode = 0x42AB },
        .{ .source = "SE_REG V2, V3", .opcode = 0x5230 },
        .{ .source = "LD_BYTE V2, 0xAB", .opcode = 0x62AB },
        .{ .source = "ADD_BYTE V2, 0xAB", .opcode = 0x72AB },
        .{ .source = "LD_REG V2, V3", .opcode = 0x8230 },
        .{ .source = "OR V2, V3", .opcode = 0x8231 },
        .{ .source = "AND V2, V3", .opcode = 0x8232 },
        .{ .source = "XOR V2, V3", .opcode = 0x8233 },
        .{ .source = "ADD_REG V2, V3", .opcode = 0x8234 },
        .{ .source = "SUB V2, V3", .opcode = 0x8235 },
        .{ .source = "SHR V2", .opcode = 0x8206 },
        .{ .source = "SUBN V2, V3", .opcode = 0x8237 },
        .{ .source = "SHL V2", .opcode = 0x820E },
        .{ .source = "SNE_REG V2, V3", .opcode = 0x9230 },
        .{ .source = "LD_I 0x345", .opcode = 0xA345 },
        .{ .source = "JP_V0 0x345", .opcode = 0xB345 },
        .{ .source = "RND V2, 0xAB", .opcode = 0xC2AB },
        .{ .source = "DRW V2, V3, 5", .opcode = 0xD235 },
        .{ .source = "SKP V2", .opcode = 0xE29E },
        .{ .source = "SKNP V2", .opcode = 0xE2A1 },
        .{ .source = "GET_DT V2", .opcode = 0xF207 },
        .{ .source = "WAIT_KEY V2", .opcode = 0xF20A },
        .{ .source = "SET_DT V2", .opcode = 0xF215 },
        .{ .source = "SET_ST V2", .opcode = 0xF218 },
        .{ .source = "ADD_I V2", .opcode = 0xF21E },
        .{ .source = "LD_FONT V2", .opcode = 0xF229 },
        .{ .source = "BCD V2", .opcode = 0xF233 },
        .{ .source = "STORE V2", .opcode = 0xF255 },
        .{ .source = "LOAD V2", .opcode = 0xF265 },
        .{ .source = "STORE VF", .opcode = 0xFF55 },
        .{ .source = "LOAD VF", .opcode = 0xFF65 },
        .{ .source = "DATA 0xFEDC", .opcode = 0xFEDC },
    };
    for (cases) |case| {
        var line: usize = 0;
        const rom = try assemble(std.testing.allocator, case.source, &line);
        defer std.testing.allocator.free(rom);
        try std.testing.expectEqualSlices(u8, &.{ @intCast(case.opcode >> 8), @truncate(case.opcode) }, rom);
    }
}

test "labels, comments, lowercase instructions, and sprite bytes" {
    const source = "; example\r\nstart: ld_i sprite\r\n jp start\n sprite: .byte 0b10000001, 255, 0x42 ; pixels\n";
    var line: usize = 0;
    const rom = try assemble(std.testing.allocator, source, &line);
    defer std.testing.allocator.free(rom);
    try std.testing.expectEqualSlices(u8, &.{ 0xA2, 0x04, 0x12, 0x00, 0x81, 0xFF, 0x42 }, rom);
}

test "invalid programs report their source line" {
    const Case = struct { source: []const u8, err: anyerror, line: usize = 1 };
    const cases = [_]Case{
        .{ .source = "JP missing", .err = error.UnknownLabel },
        .{ .source = "LD_BYTE V0, 256", .err = error.ValueOutOfRange },
        .{ .source = "JP 0x1000", .err = error.ValueOutOfRange },
        .{ .source = "DRW V0, V1, 16", .err = error.ValueOutOfRange },
        .{ .source = "LD_BYTE VG, 1", .err = error.ExpectedRegister },
        .{ .source = "ADD_BYTE V10, 1", .err = error.ExpectedRegister },
        .{ .source = "JP_V0 V1, 0x200", .err = error.WrongOperandCount },
        .{ .source = "CLS V0", .err = error.WrongOperandCount },
        .{ .source = "LD_BYTE V0,", .err = error.EmptyOperand },
        .{ .source = ".byte", .err = error.EmptyOperand },
        .{ .source = ".byte 256", .err = error.ValueOutOfRange },
        .{ .source = "DATA 65536", .err = error.InvalidNumber },
        .{ .source = "LD V0, 1", .err = error.UnknownInstruction },
        .{ .source = "ADD V0, V1", .err = error.UnknownInstruction },
        .{ .source = "SE V0, 1", .err = error.UnknownInstruction },
        .{ .source = "WAT", .err = error.UnknownInstruction },
        .{ .source = "a: CLS\na: RET", .err = error.DuplicateLabel, .line = 2 },
        .{ .source = "1a: CLS", .err = error.InvalidLabel },
        .{ .source = ".byte 1\nCLS", .err = error.UnalignedInstruction, .line = 2 },
        .{ .source = "; empty", .err = error.EmptyProgram },
    };
    for (cases) |case| {
        var line: usize = 0;
        try std.testing.expectError(case.err, assemble(std.testing.allocator, case.source, &line));
        try std.testing.expectEqual(case.line, line);
    }
}

test "ROM size limit" {
    const source = "DATA 0\n" ** (max_rom_size / 2);
    var line: usize = 0;
    const rom = try assemble(std.testing.allocator, source, &line);
    defer std.testing.allocator.free(rom);
    try std.testing.expectEqual(@as(usize, max_rom_size), rom.len);
    try std.testing.expectError(error.RomTooLarge, assemble(std.testing.allocator, source ++ ".byte 0", &line));
}
