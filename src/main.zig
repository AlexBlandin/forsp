//! Command-line entry point.
//!
//!     forsp [--trace] <path>   runs the program in a file (`-` reads stdin)
//!     forsp [--trace] --repl   reads and runs stdin line by line

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

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: Io.File.Writer = .initStreaming(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    const args = try init.minimal.args.toSlice(arena);
    var options: forsp.Options = .{};
    var repl = false;
    var rest = args[@min(args.len, 1)..];
    while (rest.len > 0) : (rest = rest[1..]) {
        if (std.mem.eql(u8, rest[0], "--trace")) {
            options.trace = true;
        } else if (std.mem.eql(u8, rest[0], "--repl")) {
            repl = true;
        } else break;
    }
    if (rest.len != @intFromBool(!repl)) {
        const name = if (args.len > 0) args[0] else "forsp";
        try stderr.print("usage: {s} [--trace] <path>|-\n       {s} [--trace] --repl\n", .{ name, name });
        return 1;
    }

    if (repl) return runRepl(io, arena, stdout, stderr, options);

    const path = rest[0];
    const input = readProgram(io, arena, path) catch |err| {
        try stderr.print("FAIL: Failed to open file: '{s}' ({t})\n", .{ path, err });
        return 1;
    };
    var interp: forsp.Interp = try .init(arena, input, stdout, options);
    interp.run() catch |err| {
        stdout.flush() catch {};
        try interp.writeFailure(err, stderr);
        return 1;
    };
    try stdout.flush();
    return 0;
}

fn readProgram(io: Io, arena: std.mem.Allocator, path: []const u8) ![]u8 {
    if (!std.mem.eql(u8, path, "-")) return Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited);
    var buffer: [4096]u8 = undefined;
    var reader = Io.File.stdin().readerStreaming(io, &buffer);
    return reader.interface.allocRemaining(arena, .unlimited);
}

/// Runs each line of stdin with `evalBody`, so definitions carry over. A line
/// that leaves a list open waits for the next. Returns 1 if anything failed.
fn runRepl(io: Io, arena: std.mem.Allocator, stdout: *Io.Writer, stderr: *Io.Writer, options: forsp.Options) !u8 {
    const prompt = Io.File.stdin().isTty(io) catch false;
    var buffer: [4096]u8 = undefined;
    var reader = Io.File.stdin().readerStreaming(io, &buffer);
    const in = &reader.interface;

    var interp: forsp.Interp = try .init(arena, "", stdout, options);
    var chunk: Io.Writer.Allocating = .init(arena);
    var status: u8 = 0;
    while (true) {
        if (prompt) {
            try stdout.writeAll(if (chunk.written().len == 0) "> " else ".. ");
            try stdout.flush();
        }
        const n = try in.streamDelimiterEnding(&chunk.writer, '\n');
        const at_end = in.bufferedLen() == 0;
        if (at_end and n == 0) break;
        if (!at_end) in.toss(1); // the newline
        try chunk.writer.writeByte('\n');

        interp.evalBody(chunk.written()) catch |err| {
            if (err == error.UnclosedList and !at_end) continue;
            try stdout.flush();
            try interp.writeFailure(err, stderr);
            try stderr.flush();
            status = 1;
        };
        chunk.clearRetainingCapacity();
        try stdout.flush();
    }
    // Input ended while a list was still open.
    if (chunk.written().len > 0) {
        interp.evalBody(chunk.written()) catch |err| {
            try stdout.flush();
            try interp.writeFailure(err, stderr);
            status = 1;
        };
    }
    try stdout.flush();
    return status;
}
