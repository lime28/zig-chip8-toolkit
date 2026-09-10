const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "emulate",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    exe.root_module.link_libc = true;
    exe.root_module.linkSystemLibrary("SDL3", .{});
    const sdl_prefix = b.option([]const u8, "sdl-prefix", "SDL3 installation prefix") orelse detectHomebrewSdl(b, target);
    if (sdl_prefix) |prefix| {
        exe.root_module.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "include" }) });
        exe.root_module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "lib" }) });
        exe.root_module.addRPath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "lib" }) });
    }
    const install_emulator = b.addInstallArtifact(exe, .{});
    const emulate_step = b.step("emulate", "Build the emulator, and run it when arguments are provided");
    emulate_step.dependOn(&install_emulator.step);
    if (b.args) |args| {
        const run_emulator = b.addRunArtifact(exe);
        run_emulator.addArgs(args);
        emulate_step.dependOn(&run_emulator.step);
    }

    const assembler = b.addExecutable(.{
        .name = "chip8-asm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/asm.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const install_assembler = b.addInstallArtifact(assembler, .{});
    const asm_step = b.step("asm", "Build the assembler, and run it when arguments are provided");
    asm_step.dependOn(&install_assembler.step);
    if (b.args) |args| {
        const run_assembler = b.addRunArtifact(assembler);
        run_assembler.addArgs(args);
        asm_step.dependOn(&run_assembler.step);
    }

    const disasm = b.addExecutable(.{
        .name = "chip8-disasm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/disasm.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const install_disasm = b.addInstallArtifact(disasm, .{});
    const disasm_step = b.step("disasm", "Build the disassembler, and run it when arguments are provided");
    disasm_step.dependOn(&install_disasm.step);
    if (b.args) |args| {
        const run_disasm = b.addRunArtifact(disasm);
        run_disasm.addArgs(args);
        disasm_step.dependOn(&run_disasm.step);
    }
}

/// Homebrew libraries are outside Zig's default macOS SDK search paths.
fn detectHomebrewSdl(b: *std.Build, target: std.Build.ResolvedTarget) ?[]const u8 {
    if (@import("builtin").os.tag != .macos or !target.query.isNative()) return null;
    const prefix = switch (target.result.cpu.arch) {
        .aarch64 => "/opt/homebrew/opt/sdl3",
        .x86_64 => "/usr/local/opt/sdl3",
        else => return null,
    };
    std.Io.Dir.accessAbsolute(b.graph.io, b.pathJoin(&.{ prefix, "include/SDL3/SDL.h" }), .{}) catch return null;
    return prefix;
}
