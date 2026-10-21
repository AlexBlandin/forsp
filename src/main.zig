//! Command-line entry point: `forsp <path>` runs the program in that file.

const std = @import("std");
const Io = std.Io;
const forsp = @import("forsp");

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const arena = init.arena.allocator();

    var stderr_buffer: [256]u8 = undefined;
    var stderr_writer: Io.File.Writer = .initStreaming(.stderr(), io, &stderr_buffer);
    const stderr = &stderr_writer.interface;
    defer stderr.flush() catch {};

    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 2) {
        try stderr.print("usage: {s} <path>\n", .{if (args.len > 0) args[0] else "forsp"});
        return 1;
    }
    const path = args[1];

    const input = Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited) catch |err| {
        try stderr.print("FAIL: Failed to open file: '{s}' ({t})\n", .{ path, err });
        return 1;
    };

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: Io.File.Writer = .initStreaming(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var interp: forsp.Interp = try .init(arena, input, stdout);
    interp.run() catch |err| {
        stdout.flush() catch {};
        try interp.writeFailure(err, stderr);
        return 1;
    };
    try stdout.flush();
    return 0;
}
