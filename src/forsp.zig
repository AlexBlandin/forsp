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

//! A Zig port of forsp.c

const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const config = @import("config");

pub const Error = error{
    CarOfNonPair,
    CdrOfNonPair,
    UnboundAtom,
    KeyNotAtom,
    StackUnderflow,
    QuoteWithoutData,
    EndOfInput,
} || Allocator.Error || Writer.Error;

/// Object kinds. The numbers are observable through the `tag` primitive.
/// Non-exhaustive because ptr-to-obj! can turn any address into an object.
pub const Tag = enum(u64) { nil = 0, atom = 1, num = 2, pair = 3, clos = 4, prim = 5, _ };

/// A heap object. Low-level programs can use the ptr-*! primitives to read
/// and write objects by byte offset (see examples/fibonacci-imperative.fp).
pub const Object = extern struct {
    tag: Tag,
    as: extern union {
        atom: [*:0]const u8,
        num: i64,
        pair: extern struct { car: *Object, cdr: *Object },
        clos: extern struct { body: *Object, env: *Object },
        /// Index into `primitives`.
        prim: usize,
    },
};

/// Interpreter state. Equivalent to `state_t` since ptr-state! exposes it
/// (see examples/low-level.fp).
pub const State = extern struct {
    input_str: [*]const u8,
    input_len: usize,
    input_pos: usize,
    nil: *Object,
    /// Objects queued by the ^ and $ read forms; `nil` when empty.
    read_stack: *Object,
    interned_atoms: *Object,
    atom_true: *Object,
    atom_quote: *Object,
    atom_push: *Object,
    atom_pop: *Object,
    /// The value stack, as a list whose car is the top.
    stack: *Object,
    /// The top-level environment, an association list of (key . value).
    env: *Object,
};

comptime {
    assert(@sizeOf(Object) == 24);
    assert(@offsetOf(Object, "as") == 8);
    assert(@offsetOf(State, "atom_true") == 6 * 8);
}

const Primitive = struct {
    name: []const u8,
    func: *const fn (self: *Interp, env: **Object) Error!void,
};

/// All primitives from forsp.c.
const primitives = [_]Primitive{
    // Core primitives
    .{ .name = "push", .func = primPush },
    .{ .name = "pop", .func = primPop },
    .{ .name = "cons", .func = primCons },
    .{ .name = "car", .func = primCar },
    .{ .name = "cdr", .func = primCdr },
    .{ .name = "eq", .func = primEq },
    .{ .name = "cswap", .func = primCswap },
    .{ .name = "tag", .func = primTag },
    .{ .name = "read", .func = primRead },
    .{ .name = "print", .func = primPrint },
    // Extra primitives
    .{ .name = "stack", .func = primStack },
    .{ .name = "env", .func = primEnv },
    .{ .name = "-", .func = primSub },
    .{ .name = "*", .func = primMul },
    .{ .name = "nand", .func = primNand },
    .{ .name = "<<", .func = primLsh },
    .{ .name = ">>", .func = primRsh },
} ++ if (config.lowlevel) [_]Primitive{
    .{ .name = "ptr-state!", .func = primPtrState },
    .{ .name = "ptr-read!", .func = primPtrRead },
    .{ .name = "ptr-write!", .func = primPtrWrite },
    .{ .name = "ptr-to-obj!", .func = primPtrToObj },
    .{ .name = "ptr-from-obj!", .func = primPtrFromObj },
} else [_]Primitive{};

/// One interpreter over one input text. Objects are never freed (there is no
/// garbage collector), so `gpa` is normally an arena.
pub const Interp = struct {
    state: State,
    gpa: Allocator,
    out: *Writer,
    /// The key of the failed lookup behind the last `error.UnboundAtom`.
    unbound: ?*Object = null,

    pub fn init(gpa: Allocator, input: []const u8, out: *Writer) Error!Interp {
        const nil = try gpa.create(Object);
        nil.* = .{ .tag = .nil, .as = undefined };
        var self: Interp = .{
            .state = .{
                .input_str = input.ptr,
                .input_len = std.mem.indexOfScalar(u8, input, 0) orelse input.len,
                .input_pos = 0,
                .nil = nil,
                .read_stack = nil,
                .interned_atoms = nil,
                .atom_true = nil,
                .atom_quote = nil,
                .atom_push = nil,
                .atom_pop = nil,
                .stack = nil,
                .env = nil,
            },
            .gpa = gpa,
            .out = out,
        };
        self.state.atom_true = try self.intern("t");
        self.state.atom_quote = try self.intern("quote");
        self.state.atom_push = try self.intern("push");
        self.state.atom_pop = try self.intern("pop");

        var env = nil;
        for (primitives, 0..) |primitive, index| {
            const prim = try self.make(.{ .tag = .prim, .as = .{ .prim = index } });
            env = try self.envDefine(env, try self.intern(primitive.name), prim);
        }
        self.state.env = env;
        return self;
    }

    /// Reads the program (the first expression of the input) and computes it.
    pub fn run(self: *Interp) Error!void {
        const program = try self.read();
        try self.compute(program, self.state.env);
    }

    /// Writes the diagnostic for an error returned by `run`.
    pub fn writeFailure(self: *const Interp, err: Error, w: *Writer) Writer.Error!void {
        try w.writeAll("FAIL: ");
        switch (err) {
            error.CarOfNonPair => try w.writeAll("Expected pair to apply car() function"),
            error.CdrOfNonPair => try w.writeAll("Expected pair to apply cdr() function"),
            error.UnboundAtom => {
                const key = if (self.unbound) |k| std.mem.span(k.as.atom) else "";
                // "find in key" is forsp.c's wording, kept for identical diagnostics.
                try w.print("Failed to find in key='{s}' in environment", .{key});
            },
            error.KeyNotAtom => try w.writeAll("Expected 'key' to be an atom in env_find()"),
            error.StackUnderflow => try w.writeAll("Value Stack Underflow"),
            error.QuoteWithoutData => try w.writeAll("Expected data following a quote form"),
            error.EndOfInput => try w.writeAll("End of input: could not read()"),
            error.OutOfMemory => try w.writeAll("Out of memory"),
            error.WriteFailed => try w.writeAll("Failed to write output"),
        }
        try w.writeByte('\n');
    }

    fn make(self: *Interp, obj: Object) Allocator.Error!*Object {
        const ptr = try self.gpa.create(Object);
        ptr.* = obj;
        return ptr;
    }

    fn makeNum(self: *Interp, num: i64) Allocator.Error!*Object {
        return self.make(.{ .tag = .num, .as = .{ .num = num } });
    }

    fn makePair(self: *Interp, car_: *Object, cdr_: *Object) Allocator.Error!*Object {
        return self.make(.{ .tag = .pair, .as = .{ .pair = .{ .car = car_, .cdr = cdr_ } } });
    }

    fn makeClos(self: *Interp, body: *Object, env: *Object) Allocator.Error!*Object {
        return self.make(.{ .tag = .clos, .as = .{ .clos = .{ .body = body, .env = env } } });
    }

    fn intern(self: *Interp, name: []const u8) Error!*Object {
        var list = self.state.interned_atoms;
        while (list != self.state.nil) : (list = try cdr(list)) {
            const atom = try car(list);
            assert(atom.tag == .atom);
            if (std.mem.eql(u8, std.mem.span(atom.as.atom), name)) return atom;
        }
        const atom = try self.make(.{ .tag = .atom, .as = .{ .atom = try self.gpa.dupeSentinel(u8, name, 0) } });
        self.state.interned_atoms = try self.makePair(atom, self.state.interned_atoms);
        return atom;
    }

    fn car(obj: *Object) Error!*Object {
        if (obj.tag != .pair) return error.CarOfNonPair;
        return obj.as.pair.car;
    }

    fn cdr(obj: *Object) Error!*Object {
        if (obj.tag != .pair) return error.CdrOfNonPair;
        return obj.as.pair.cdr;
    }

    /// Numbers compare by value; everything else by identity (atoms are interned).
    fn objEqual(a: *Object, b: *Object) bool {
        return a == b or (a.tag == .num and b.tag == .num and a.as.num == b.as.num);
    }

    /// Arithmetic treats anything that is not a number as 0.
    fn objI64(obj: *Object) i64 {
        return if (obj.tag == .num) obj.as.num else 0;
    }

    fn peek(self: *const Interp) u8 {
        if (self.state.input_pos == self.state.input_len) return 0;
        return self.state.input_str[self.state.input_pos];
    }

    fn advance(self: *Interp) void {
        assert(self.peek() != 0); // invalid to advance beyond the end
        self.state.input_pos += 1;
    }

    fn isWhite(c: u8) bool {
        return c == ' ' or c == '\t' or c == '\n';
    }

    fn isDirective(c: u8) bool {
        return c == '\'' or c == '^' or c == '$';
    }

    fn isPunctuation(c: u8) bool {
        return c == 0 or isWhite(c) or isDirective(c) or c == '(' or c == ')' or c == ';';
    }

    fn skipWhiteAndComments(self: *Interp) void {
        while (true) {
            const c = self.peek();
            if (isWhite(c)) {
                self.advance();
            } else if (c == ';') {
                while (self.peek() != 0) {
                    const skipped = self.peek();
                    self.advance();
                    if (skipped == '\n') break;
                }
            } else return;
        }
    }

    fn read(self: *Interp) Error!*Object {
        const queued = self.state.read_stack;
        if (queued != self.state.nil) {
            self.state.read_stack = try cdr(queued);
            return car(queued);
        }

        self.skipWhiteAndComments();
        const c = self.peek();
        switch (c) {
            0 => return error.EndOfInput,
            '\'' => {
                self.advance();
                return self.state.atom_quote;
            },
            // ^x reads as `quote x push` and $x as `quote x pop`.
            '^', '$' => {
                self.advance();
                const key = try self.readScalar();
                const op = if (c == '^') self.state.atom_push else self.state.atom_pop;
                self.state.read_stack = try self.makePair(key, try self.makePair(op, self.state.nil));
                return self.state.atom_quote;
            },
            '(' => {
                self.advance();
                return self.readList();
            },
            else => return self.readScalar(),
        }
    }

    fn readList(self: *Interp) Error!*Object {
        const nil = self.state.nil;
        var head = nil;
        var tail: ?*Object = null;
        while (true) {
            // Queued objects from ^ or $ always belong to this list.
            if (self.state.read_stack == nil) {
                self.skipWhiteAndComments();
                if (self.peek() == ')') {
                    self.advance();
                    return head;
                }
            }
            const cell = try self.makePair(try self.read(), nil);
            if (tail) |last| last.as.pair.cdr = cell else head = cell;
            tail = cell;
        }
    }

    fn readScalar(self: *Interp) Error!*Object {
        const start = self.state.input_pos;
        while (!isPunctuation(self.peek())) self.advance();
        const token = self.state.input_str[start..self.state.input_pos];
        if (parseI64(token)) |num| return self.makeNum(num);
        return self.intern(token);
    }

    /// A token is a number when atoll() gives non-zero, or the token is exactly
    /// "0". atoll() reads an optional sign and the longest digit prefix after
    /// any leading isspace() characters (only \r, \v and \f can reach it here),
    /// so "12abc" is 12 and "00" is an atom; by glibc behaviour.
    fn parseI64(token: []const u8) ?i64 {
        var i: usize = 0;
        while (i < token.len and std.ascii.isWhitespace(token[i])) i += 1;
        var negative = false;
        if (i < token.len and (token[i] == '+' or token[i] == '-')) {
            negative = token[i] == '-';
            i += 1;
        }
        var n: i64 = 0;
        while (i < token.len and std.ascii.isDigit(token[i])) : (i += 1) {
            const digit: i64 = token[i] - '0';
            n = if (negative) n *| 10 -| digit else n *| 10 +| digit;
        }
        if (n == 0 and !std.mem.eql(u8, token, "0")) return null;
        return n;
    }

    fn print(self: *Interp, obj: *Object) Writer.Error!void {
        try self.printRecurse(obj);
        try self.out.writeByte('\n');
    }

    fn printRecurse(self: *Interp, obj: *Object) Writer.Error!void {
        const w = self.out;
        if (obj == self.state.nil) return w.writeAll("()");
        switch (obj.tag) {
            .atom => try w.writeAll(std.mem.span(obj.as.atom)),
            .num => try w.print("{d}", .{obj.as.num}),
            .pair => {
                try w.writeByte('(');
                try self.printRecurse(obj.as.pair.car);
                var rest = obj.as.pair.cdr;
                while (rest != self.state.nil) : (rest = rest.as.pair.cdr) {
                    if (rest.tag != .pair) {
                        try w.writeAll(" . ");
                        try self.printRecurse(rest);
                        break;
                    }
                    try w.writeByte(' ');
                    try self.printRecurse(rest.as.pair.car);
                }
                try w.writeByte(')');
            },
            .clos => {
                try w.writeAll("CLOSURE<");
                try self.printRecurse(obj.as.clos.body);
                try w.print(", 0x{x}>", .{@intFromPtr(obj.as.clos.env)});
            },
            .prim => try w.print("PRIM<0x{x}>", .{if (obj.as.prim < primitives.len)
                @intFromPtr(primitives[obj.as.prim].func)
            else
                obj.as.prim}),
            .nil, _ => {},
        }
    }

    // Environment: a list of (key . value) pairs, newest first.

    fn envFind(self: *Interp, env: *Object, key: *Object) Error!*Object {
        if (key.tag != .atom) return error.KeyNotAtom;
        var list = env;
        while (list != self.state.nil) : (list = try cdr(list)) {
            const kv = try car(list);
            if (key == try car(kv)) return cdr(kv);
        }
        self.unbound = key;
        return error.UnboundAtom;
    }

    fn envDefine(self: *Interp, env: *Object, key: *Object, val: *Object) Allocator.Error!*Object {
        return self.makePair(try self.makePair(key, val), env);
    }

    fn push(self: *Interp, obj: *Object) Allocator.Error!void {
        self.state.stack = try self.makePair(obj, self.state.stack);
    }

    fn pop(self: *Interp) Error!*Object {
        const stack = self.state.stack;
        if (stack == self.state.nil) return error.StackUnderflow;
        self.state.stack = try cdr(stack);
        return car(stack);
    }

    fn compute(self: *Interp, comp_in: *Object, env_in: *Object) Error!void {
        if (config.trace) {
            try self.out.writeAll("compute: ");
            try self.print(comp_in);
        }
        var comp = comp_in;
        var env = env_in;
        while (comp != self.state.nil) {
            const cmd = try car(comp);
            comp = try cdr(comp);
            if (cmd == self.state.atom_quote) {
                if (comp == self.state.nil) return error.QuoteWithoutData;
                try self.push(try car(comp));
                comp = try cdr(comp);
                continue;
            }
            // atoms and (...) get ordinary eval
            try self.eval(cmd, &env);
        }
    }

    fn eval(self: *Interp, expr: *Object, env: **Object) Error!void {
        if (config.trace) {
            try self.out.writeAll("eval: ");
            try self.print(expr);
        }
        switch (expr.tag) {
            .atom => {
                const val = try self.envFind(env.*, expr);
                switch (val.tag) {
                    .clos => try self.compute(val.as.clos.body, val.as.clos.env),
                    .prim => try primitives[val.as.prim].func(self, env),
                    else => try self.push(val),
                }
            },
            .nil, .pair => try self.push(try self.makeClos(expr, env.*)),
            else => try self.push(expr),
        }
    }
};

fn primPush(self: *Interp, env: **Object) Error!void {
    try self.push(try self.envFind(env.*, try self.pop()));
}

fn primPop(self: *Interp, env: **Object) Error!void {
    const key = try self.pop();
    const val = try self.pop();
    env.* = try self.envDefine(env.*, key, val);
}

fn primEq(self: *Interp, _: **Object) Error!void {
    const equal = Interp.objEqual(try self.pop(), try self.pop());
    try self.push(if (equal) self.state.atom_true else self.state.nil);
}

fn primCons(self: *Interp, _: **Object) Error!void {
    const a = try self.pop();
    const b = try self.pop();
    try self.push(try self.makePair(a, b));
}

fn primCar(self: *Interp, _: **Object) Error!void {
    try self.push(try Interp.car(try self.pop()));
}

fn primCdr(self: *Interp, _: **Object) Error!void {
    try self.push(try Interp.cdr(try self.pop()));
}

fn primCswap(self: *Interp, _: **Object) Error!void {
    if (try self.pop() == self.state.atom_true) {
        const a = try self.pop();
        const b = try self.pop();
        try self.push(a);
        try self.push(b);
    }
}

fn primTag(self: *Interp, _: **Object) Error!void {
    try self.push(try self.makeNum(@bitCast(@backingInt((try self.pop()).tag))));
}

fn primRead(self: *Interp, _: **Object) Error!void {
    try self.push(try self.read());
}

fn primPrint(self: *Interp, _: **Object) Error!void {
    try self.print(try self.pop());
}

fn primStack(self: *Interp, _: **Object) Error!void {
    try self.push(self.state.stack);
}

fn primEnv(self: *Interp, env: **Object) Error!void {
    try self.push(env.*);
}

/// Pops `b` then `a` and pushes `op(a, b)`.
fn binaryOp(self: *Interp, comptime op: fn (i64, i64) i64) Error!void {
    const b = Interp.objI64(try self.pop());
    const a = Interp.objI64(try self.pop());
    try self.push(try self.makeNum(op(a, b)));
}

fn primSub(self: *Interp, _: **Object) Error!void {
    try binaryOp(self, struct {
        fn f(a: i64, b: i64) i64 {
            return a -% b;
        }
    }.f);
}

fn primMul(self: *Interp, _: **Object) Error!void {
    try binaryOp(self, struct {
        fn f(a: i64, b: i64) i64 {
            return a *% b;
        }
    }.f);
}

fn primNand(self: *Interp, _: **Object) Error!void {
    try binaryOp(self, struct {
        fn f(a: i64, b: i64) i64 {
            return ~(a & b);
        }
    }.f);
}

fn primLsh(self: *Interp, _: **Object) Error!void {
    try binaryOp(self, struct {
        fn f(a: i64, b: i64) i64 {
            return std.math.shl(i64, a, b);
        }
    }.f);
}

fn primRsh(self: *Interp, _: **Object) Error!void {
    try binaryOp(self, struct {
        fn f(a: i64, b: i64) i64 {
            return std.math.shr(i64, a, b);
        }
    }.f);
}

fn addressOf(num: i64) usize {
    return @intCast(@as(u64, @bitCast(num)));
}

fn numberOf(address: usize) i64 {
    return @bitCast(@as(u64, address));
}

fn primPtrState(self: *Interp, _: **Object) Error!void {
    try self.push(try self.makeNum(numberOf(@intFromPtr(&self.state))));
}

fn primPtrRead(self: *Interp, _: **Object) Error!void {
    const ptr: *align(1) const i64 = @ptrFromInt(addressOf(Interp.objI64(try self.pop())));
    try self.push(try self.makeNum(ptr.*));
}

fn primPtrWrite(self: *Interp, _: **Object) Error!void {
    const val = try self.pop();
    const ptr: *align(1) i64 = @ptrFromInt(addressOf(Interp.objI64(try self.pop())));
    ptr.* = Interp.objI64(val);
}

fn primPtrToObj(self: *Interp, _: **Object) Error!void {
    // Unsafe as forsp.c turns any number into an object pointer.
    @setRuntimeSafety(false);
    try self.push(@ptrFromInt(addressOf(Interp.objI64(try self.pop()))));
}

fn primPtrFromObj(self: *Interp, _: **Object) Error!void {
    try self.push(try self.makeNum(numberOf(@intFromPtr(try self.pop()))));
}

/// Runs `source` as a whole program and returns what it printed.
fn runProgram(arena: Allocator, source: []const u8) ![]u8 {
    var out: Writer.Allocating = .init(arena);
    var interp: Interp = try .init(arena, source, &out.writer);
    try interp.run();
    return out.written();
}

fn expectOutput(source: []const u8, expected: []const u8) !void {
    if (config.trace) return error.SkipZigTest; // trace lines go to the same output
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings(expected, try runProgram(arena.allocator(), source));
}

fn expectFailure(source: []const u8, expected: anyerror) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(expected, runProgram(arena.allocator(), source));
}

test "print: numbers, nil and the true atom" {
    try expectOutput("(42 print -7 print '() print 1 1 eq print)", "42\n-7\n()\nt\n");
}

test "read: quoted data is pushed unevaluated" {
    try expectOutput("('foo print '(1 (2 3) bar) print)", "foo\n(1 (2 3) bar)\n");
}

test "read: comments and tabs are skipped" {
    try expectOutput("( ; a comment\n\t1 print ; another\n)", "1\n");
}

test "read: number tokens follow atoll, so a digit prefix makes a number" {
    try expectOutput("('12abc print '+5 print '-3 print)", "12\n5\n-3\n");
}

test "read: zero-valued tokens other than 0 are atoms" {
    try expectOutput("('0 print '00 print '-0 print '- print 'x0 print)", "0\n00\n-0\n-\nx0\n");
}

test "read: numbers saturate like glibc atoll" {
    try expectOutput("('99999999999999999999 print '-99999999999999999999 print)", "9223372036854775807\n-9223372036854775808\n");
}

test "read: number tokens skip the leading whitespace atoll skips" {
    try expectOutput("('\r5 print '\x0b-6 print '\x0c7 print)", "5\n-6\n7\n");
}

test "low-level: ptr-to-obj! accepts null and unaligned addresses" {
    if (!config.lowlevel) return error.SkipZigTest;
    try expectOutput("(0 ptr-to-obj! ptr-from-obj! print 1 ptr-to-obj! ptr-from-obj! print)", "0\n1\n");
}

test "low-level: printing a forged primitive shows its raw word" {
    if (!config.lowlevel) return error.SkipZigTest;
    try expectOutput("(42 $n ^n ptr-from-obj! 5 ptr-write! ^n print)", "PRIM<0x2a>\n");
}

test "read: ^x and $x desugar to quote/push and quote/pop" {
    try expectOutput("('(^x $y) print)", "(quote x push quote y pop)\n");
}

test "failure: a program that is not a list" {
    try expectFailure("7", error.CarOfNonPair);
}

test "read: the read primitive consumes input after the program" {
    try expectOutput("(read print read print) (a b) 5", "(a b)\n5\n");
}

test "print: dotted pairs and nested lists" {
    try expectOutput("('b 'a cons print '(1 2) '(3) cons print)", "(a . b)\n((3) 1 2)\n");
}

test "print: closures show body and environment address" {
    if (config.trace) return error.SkipZigTest; // trace lines go to the same output
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const out = try runProgram(arena.allocator(), "((1 x) print)");
    try testing.expectStringStartsWith(out, "CLOSURE<(1 x), 0x");
    try testing.expectStringEndsWith(out, ">\n");
}

test "print: primitives show an address" {
    if (config.trace) return error.SkipZigTest; // trace lines go to the same output
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const out = try runProgram(arena.allocator(), "('car push print)");
    try testing.expectStringStartsWith(out, "PRIM<0x");
}

test "pop and push bind and look up names" {
    try expectOutput("(5 $x ^x print ^x ^x * print)", "5\n25\n");
}

test "closures capture their defining environment" {
    try expectOutput("(1 $x (^x) $get 2 $x get print)", "1\n");
}

test "pop inside a closure does not leak to the caller" {
    try expectOutput("(1 $x (2 $x) $f f ^x print)", "1\n");
}

test "eq compares numbers by value and everything else by identity" {
    try expectOutput("(3 3 eq print 'a 'a eq print '(1) '(1) eq print 3 4 eq print)", "t\nt\n()\n()\n");
}

test "cons, car and cdr" {
    try expectOutput("('(2 3) 1 cons $l ^l car print ^l cdr print)", "1\n(2 3)\n");
}

test "cswap swaps only when the condition is t" {
    try expectOutput("(1 2 't cswap print print 1 2 '() cswap print print)", "1\n2\n2\n1\n");
}

test "tag reports the object kind" {
    try expectOutput("('() tag print 'a tag print 1 tag print '(1) tag print (1) tag print 'car push tag print)", "0\n1\n2\n3\n4\n5\n");
}

test "stack and env primitives" {
    try expectOutput("(1 2 stack print)", "(2 1)\n");
    try expectOutput("('() $e 1 $x env car print)", "(x . 1)\n");
}

test "arithmetic and bitwise primitives" {
    try expectOutput("(10 3 - print 6 7 * print 12 10 nand print 1 4 << print -16 2 >> print)", "7\n42\n-9\n16\n-4\n");
}

test "arithmetic on non-numbers treats them as zero" {
    try expectOutput("('a 3 - print)", "-3\n");
}

test "arithmetic wraps on overflow" {
    try expectOutput("(9223372036854775807 -1 - print)", "-9223372036854775808\n");
}

test "low-level: ptr-from-obj! and ptr-to-obj! round-trip" {
    if (!config.lowlevel) return error.SkipZigTest;
    try expectOutput("('(1 2) ptr-from-obj! ptr-to-obj! print)", "(1 2)\n");
}

test "low-level: ptr-write! sets the car of a pair" {
    if (!config.lowlevel) return error.SkipZigTest;
    try expectOutput("('(1 2) $l ^l ptr-from-obj! 0 8 - - 'z ptr-from-obj! ptr-write! ^l print)", "(z 2)\n");
}

test "failure: unbound atom" {
    try expectFailure("(nope)", error.UnboundAtom);
}

test "failure: car of a non-pair" {
    try expectFailure("(1 car)", error.CarOfNonPair);
}

test "failure: cdr of a non-pair" {
    try expectFailure("(1 cdr)", error.CdrOfNonPair);
}

test "failure: value stack underflow" {
    try expectFailure("(print)", error.StackUnderflow);
}

test "failure: quote with nothing after it" {
    try expectFailure("(1 ')", error.QuoteWithoutData);
}

test "failure: push of a non-atom key" {
    try expectFailure("(1 push)", error.KeyNotAtom);
}

test "failure: end of input inside a list" {
    try expectFailure("(1 2", error.EndOfInput);
}

test "failure: empty program" {
    try expectFailure(" ; nothing\n", error.EndOfInput);
}

test "golden: every example prints what forsp.c prints" {
    if (config.trace) return error.SkipZigTest; // trace lines go to the same output
    const names = @import("examples").names;
    const needs_lowlevel = [_][]const u8{ "fibonacci-imperative", "low-level" };
    inline for (names) |name| skip: {
        if (!config.lowlevel) for (needs_lowlevel) |n| if (std.mem.eql(u8, n, name)) break :skip;
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const got = try runProgram(arena.allocator(), @embedFile("example/" ++ name));
        const want = @embedFile("expected/" ++ name);
        testing.expectEqualStrings(want, try normaliseAddresses(arena.allocator(), got)) catch |err| {
            std.debug.print("example: {s}\n", .{name});
            return err;
        };
    }
}

/// Replaces each `0x<hex>>` with `0xADDR>`, as with the expected outputs.
fn normaliseAddresses(arena: Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        if (std.mem.startsWith(u8, text[i..], "0x")) {
            var j = i + 2;
            while (j < text.len and std.ascii.isHex(text[j])) j += 1;
            if (j > i + 2 and j < text.len and text[j] == '>') {
                try out.appendSlice(arena, "0xADDR");
                i = j;
                continue;
            }
        }
        try out.append(arena, text[i]);
        i += 1;
    }
    return out.items;
}
