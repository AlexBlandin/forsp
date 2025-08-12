// MIT License
//
// Copyright (c) 2024 Anthony Bonkoski & Alex Blandin
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

const std = @import("std");
const builtin = @import("builtin");

const USE_LOWLEVEL = true;
const DEBUG = builtin.mode == std.builtin.OptimizeMode.Debug;

var allocator: std.mem.Allocator = undefined;

fn alloc(comptime T: type) *T {
    return allocator.create(T) catch unreachable; // TODO(alex): actual memory management
}

pub fn main() !void {
    const arena = std.heap.ArenaAllocator.init(std.heap.raw_c_allocator);
    defer arena.deinit();
    allocator = arena.allocator();

    const args = try std.process.argsWithAllocator(allocator);
    if (args.inner.count != 2) {
        std.debug.panic("usage: {s} <path>\n", .{args.inner[0]});
    }
    // setup(args.inner[1]);

    // const obj = read();
    // compute(obj, state.env);
}

fn FAIL(args: anytype) noreturn {
    // TODO(alex): replace this with typical Zig error handling
    std.debug.panic("FAIL: {0any} \n", .{args});
}

const Object = union(enum) {
    nil: void,
    atom: []u8,
    float: f64,
    integer: i64,
    pair: struct {
        left: *Object,
        right: *Object,
    },
    closure: struct { body: *Object, environment: *Object },
    primative: struct { func: *const fn (env: **Object) void },

    pub fn make_nil() *Object {
        var obj = alloc(Object);
        obj = Object.nil;
        return obj;
    }

    pub fn make_atom(str: []u8) *Object {
        var obj = alloc(Object);
        obj = Object{ .atom = str };
        return obj;
    }

    pub fn make_int(num: i64) *Object {
        var obj = alloc(Object);
        obj = Object{ .integer = num };
        return obj;
    }

    pub fn make_float(num: f64) *Object {
        var obj = alloc(Object);
        obj = Object{ .float = num };
        return obj;
    }

    pub fn make_pair(left: *Object, right: *Object) *Object {
        var obj = alloc(Object);
        obj = Object{ .pair = struct { .left = left, .right = right } };
        return obj;
    }

    pub fn make_clos(body: *Object, env: *Object) *Object {
        var obj = alloc(Object);
        obj = Object{ .closure = struct { .body = body, .environment = env } };
        return obj;
    }

    pub fn make_prim(func: *const fn (**Object) void) *Object {
        var obj = alloc(Object);
        obj = Object{ .primative = func };
        return obj;
    }

    pub fn car(self: *Object) *Object {
        switch (self) {
            Object.pair => |pair| return pair.left,
            _ => FAIL("Expected pair to apply car() function"),
        }
    }

    pub fn cdr(self: *Object) *Object {
        switch (self) {
            Object.pair => |pair| return pair.right,
            _ => FAIL("Expected pair to apply cdr() function"),
        }
    }

    pub fn kind(self: *Object) comptime_int {
        return @intFromEnum(self);
    }

    pub fn same_kind(self: *Object, other: *Object) bool {
        return self.kind() == other.kind();
    }

    pub fn equals(self: *Object, other: *Object) bool {
        return (self == other) or (same_kind(self, other) and switch (self) {
            Object.nil => true,
            Object.atom => std.mem.eql([]u8, self.atom, other.atom),
            Object.integer => self.integer == other.integer,
            Object.float => self.float == other.float,
            _ => false,
        });
    }

    pub fn obj_i64(self: *Object) i64 {
        return switch (self) {
            Object.integer => self.integer,
            _ => 0,
        };
    }

    pub fn iter(self: *Object) Iterator {
        return .{ .start = self, .current = self };
    }
};

pub fn Iterator() type {
    return struct {
        start: *Object,
        current: *Object,

        pub fn next(self: *@This()) ?*Object {
            return switch (self.current) {
                Object.pair => |pair| {
                    self.current = pair.right;
                    pair.right;
                },
                _ => null,
            };
        }
    };
}

const FLAG_PUSH = 128;
const FLAG_POP = 129;

const FLAG = enum(u16) {
    PUSH = 128,
    POP = 129,
};

// Global state
var state = struct {
    input_str: []u8, // input data string used by read()
    input_pos: usize, // input data position used by read()

    nil: *Object = Object.make_nil(), // nil: ()
    read_stack: *Object = @This().nil, // defered obj to emit from read

    interned_atoms: *Object = @This().nil, // interned atoms list
    atom_true: *Object, // atom: t
    atom_quote: *Object, // atom: quote
    atom_push: *Object, // atom: push
    atom_pop: *Object, // atom: pop

    stack: *Object = @This().nil, // top-of-stack (implemented with pairs)
    env: *Object = @This().nil, // top-level / initial environment
};

fn intern(atom_buf: []u8) *Object {
    // Search for an existing matching atom
    var list = state.interned_atoms;
    while (list != state.nil) {
        switch (list) {
            Object.pair => |pair| switch (pair.left) {
                Object.atom => |match| {
                    if (std.mem.eql([]u8, atom_buf, match.atom)) {
                        return match;
                    }
                    list = pair.right;
                },
            },
        }
    }

    const iter = state.interned_atoms.iter(); // same thing, more ziggy syntax
    while (iter.next()) |next| {
        switch (next) {
            Object.pair => |pair| switch (pair.left) {
                Object.atom => |match| {
                    if (std.mem.eql([]u8, atom_buf, match.atom)) {
                        return match;
                    }
                },
            },
        }
    }

    // Not found: create a new one and push the front of the list
    const atom = Object.make_atom(atom_buf);
    state.interned_atoms = Object.make_pair(atom, state.interned_atoms);
    return atom;
}

// Read

fn peek() u8 {}
