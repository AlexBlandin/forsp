//! Benchmark runner: `bench <path>...` runs each program several times
//! in-process and prints the fastest and median wall-clock times.

const std = @import("std");
const Io = std.Io;
const forsp = @import("forsp");

const runs = 7;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer: Io.File.Writer = .initStreaming(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    const args = try init.minimal.args.toSlice(arena);
    for (args[1..]) |path| {
        const input = try Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited);
        var times: [runs]u64 = undefined;
        for (&times) |*time| {
            // A fresh arena per run, so every run allocates from scratch.
            var run_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
            defer run_arena.deinit();
            var discard_buffer: [256]u8 = undefined;
            var discard: Io.Writer.Discarding = .init(&discard_buffer);
            var interp: forsp.Interp = try .init(run_arena.allocator(), input, &discard.writer, .{});
            const start: Io.Clock.Timestamp = .now(io, .awake);
            try interp.run();
            time.* = @intCast(start.untilNow(io).raw.nanoseconds);
        }
        std.mem.sort(u64, &times, {}, std.sort.asc(u64));
        try stdout.print("{s}: min {d:.2} ms, median {d:.2} ms ({d} runs)\n", .{
            std.fs.path.basename(path), ms(times[0]), ms(times[runs / 2]), runs,
        });
    }
}

fn ms(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
}
