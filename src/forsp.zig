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
    UnclosedList,
    RecursionTooDeep,
    /// A host primitive called `Interp.fail`.
    PrimitiveFailed,
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

/// A primitive gets the interpreter and the environment of the code calling
/// it, which it may replace (as `pop` does to bind a name). It must not call
/// `run` or `evalBody`, which reset the frames of the program calling it.
pub const Primitive = struct {
    name: []const u8,
    func: *const fn (interp: *Interp, env: **Object) Error!void,
};

/// All primitives from forsp.c.
const builtins = [_]Primitive{
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

pub const Options = struct {
    /// Print every compute and eval step to the output, as forsp.c's DEBUG does.
    trace: bool = false,
    /// Most closure calls in progress at once; deeper recursion fails with
    /// `error.RecursionTooDeep`. Tail calls replace their caller, so they do
    /// not add to the depth.
    max_depth: usize = 1 << 20,
    /// Defined after the built-in primitives, so a host primitive with a
    /// built-in name shadows it.
    primitives: []const Primitive = &.{},
};

/// One interpreter over one input text. Objects are never freed (there is no
/// garbage collector), so `gpa` is normally an arena.
pub const Interp = struct {
    state: State,
    gpa: Allocator,
    out: *Writer,
    options: Options,
    /// The built-in primitives followed by `options.primitives`.
    primitives: []const Primitive,
    /// Closure calls in progress, innermost last. Left as they were when
    /// `run` fails.
    frames: std.ArrayList(Frame) = .empty,
    open_lists: std.ArrayList(OpenList) = .empty,
    print_tasks: std.ArrayList(PrintTask) = .empty,
    /// Every atom by its name when interned. A program that rewrites
    /// `interned_atoms`, or an atom's name, through ptr-write! does not change it.
    atom_index: std.StringHashMapUnmanaged(*Object) = .empty,
    /// The key of the failed lookup behind the last `error.UnboundAtom`.
    unbound: ?*Object = null,
    /// The message behind the last `error.PrimitiveFailed`.
    failure_message: []const u8 = "",

    pub fn init(gpa: Allocator, input: []const u8, out: *Writer, options: Options) Error!Interp {
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
            .options = options,
            .primitives = if (options.primitives.len == 0)
                &builtins
            else
                try std.mem.concat(gpa, Primitive, &.{ &builtins, options.primitives }),
        };
        self.state.atom_true = try self.intern("t");
        self.state.atom_quote = try self.intern("quote");
        self.state.atom_push = try self.intern("push");
        self.state.atom_pop = try self.intern("pop");

        var env = nil;
        for (self.primitives, 0..) |primitive, index| {
            const prim = try self.make(.{ .tag = .prim, .as = .{ .prim = index } });
            env = try self.envDefine(env, try self.intern(primitive.name), prim);
        }
        self.state.env = env;
        return self;
    }

    /// Reads the program (the first expression of the input) and computes it.
    pub fn run(self: *Interp) Error!void {
        self.frames.clearRetainingCapacity();
        const program = try self.read();
        _ = try self.compute(program, self.state.env);
    }

    /// Reads every form in `input` and computes them as one body in the
    /// top-level environment, so definitions and the value stack carry over
    /// to the next call. The whole input is read first, so the `read`
    /// primitive sees the end of input. `input` must outlive the call.
    pub fn evalBody(self: *Interp, input: []const u8) Error!void {
        self.state.input_str = input.ptr;
        self.state.input_len = std.mem.indexOfScalar(u8, input, 0) orelse input.len;
        self.state.input_pos = 0;
        self.state.read_stack = self.state.nil;
        self.frames.clearRetainingCapacity();

        var body = self.state.nil;
        var last: ?*Object = null;
        while (true) {
            self.skipWhitespaceAndComments();
            if (self.peek() == 0 and self.state.read_stack == self.state.nil) break;
            const stray_paren = self.peek() == ')' and self.state.read_stack == self.state.nil;
            const cell = try self.makePair(try self.read(), self.state.nil);
            // A top-level ) reads as the empty atom, as in file mode, but read
            // leaves it in the input; step past it so the loop ends.
            if (stray_paren) self.advance();
            if (last) |l| l.as.pair.cdr = cell else body = cell;
            last = cell;
        }
        self.state.env = self.compute(body, self.state.env) catch |err| {
            // Keep the definitions made before the failure, as the value
            // stack keeps its changes. The body's frame is the first one.
            if (self.frames.items.len > 0) self.state.env = self.frames.items[0].env;
            return err;
        };
    }

    /// Fails the running program with `message`, which must outlive the
    /// interpreter. For host primitives: `return interp.fail("...")`.
    pub fn fail(self: *Interp, message: []const u8) Error {
        self.failure_message = message;
        return error.PrimitiveFailed;
    }

    /// Writes the diagnostic for an error returned by `run` or `evalBody`:
    /// forsp.c's message on the first line, then any detail on further lines.
    pub fn writeFailure(self: *const Interp, err: Error, w: *Writer) Writer.Error!void {
        try w.writeAll("FAIL: ");
        switch (err) {
            error.CarOfNonPair => try w.writeAll("Expected pair to apply car() function"),
            error.CdrOfNonPair => try w.writeAll("Expected pair to apply cdr() function"),
            error.UnboundAtom => {
                const key = if (self.unbound) |k| std.mem.span(k.as.atom) else "";
                try w.print("Failed to find in key='{s}' in environment", .{key});
            },
            error.KeyNotAtom => try w.writeAll("Expected 'key' to be an atom in env_find()"),
            error.StackUnderflow => try w.writeAll("Value Stack Underflow"),
            error.QuoteWithoutData => try w.writeAll("Expected data following a quote form"),
            error.EndOfInput, error.UnclosedList => try w.writeAll("End of input: could not read()"),
            error.OutOfMemory => try w.writeAll("Out of memory"),
            error.WriteFailed => try w.writeAll("Failed to write output"),
            error.RecursionTooDeep => try w.writeAll("Recursion too deep"),
            error.PrimitiveFailed => try w.writeAll(self.failure_message),
        }
        try w.writeByte('\n');

        if (err == error.UnclosedList) {
            const list = self.open_lists.items[self.open_lists.items.len - 1];
            const at = self.lineAndColumn(list.pos);
            try w.print("  unclosed '(' at line {d}, column {d}\n", .{ at.line, at.column });
        }
        try self.writeCallChain(w);
    }

    /// Names the closures being run when a program failed, innermost first.
    fn writeCallChain(self: *const Interp, w: *Writer) Writer.Error!void {
        const shown_max = 10;
        var named: usize = 0;
        var i = self.frames.items.len;
        while (i > 0) {
            i -= 1;
            const name = self.frames.items[i].name orelse continue;
            if (named < shown_max) {
                try w.writeAll(if (named == 0) "  in: " else " <- ");
                try w.writeAll(std.mem.span(name.as.atom));
            }
            named += 1;
        }
        if (named > shown_max) try w.print(" <- ... ({d} more)", .{named - shown_max});
        if (named > 0) try w.writeByte('\n');
    }

    /// 1-based line and byte column of input position `pos`.
    fn lineAndColumn(self: *const Interp, pos: usize) struct { line: usize, column: usize } {
        const before = self.state.input_str[0..@min(pos, self.state.input_len)];
        const line_start = if (std.mem.lastIndexOfScalar(u8, before, '\n')) |nl| nl + 1 else 0;
        return .{ .line = std.mem.countScalar(u8, before, '\n') + 1, .column = before.len - line_start + 1 };
    }

    fn make(self: *Interp, obj: Object) Allocator.Error!*Object {
        const ptr = try self.gpa.create(Object);
        ptr.* = obj;
        return ptr;
    }

    pub fn makeNum(self: *Interp, num: i64) Allocator.Error!*Object {
        return self.make(.{ .tag = .num, .as = .{ .num = num } });
    }

    pub fn makePair(self: *Interp, car_: *Object, cdr_: *Object) Allocator.Error!*Object {
        return self.make(.{ .tag = .pair, .as = .{ .pair = .{ .car = car_, .cdr = cdr_ } } });
    }

    fn makeClos(self: *Interp, body: *Object, env: *Object) Allocator.Error!*Object {
        return self.make(.{ .tag = .clos, .as = .{ .clos = .{ .body = body, .env = env } } });
    }

    /// Returns the atom named `name`, creating it on first use. New atoms go
    /// on `state.interned_atoms` and in `atom_index` for lookup.
    pub fn intern(self: *Interp, name: []const u8) Error!*Object {
        if (self.atom_index.get(name)) |atom| return atom;
        const atom = try self.make(.{ .tag = .atom, .as = .{ .atom = try self.gpa.dupeSentinel(u8, name, 0) } });
        self.state.interned_atoms = try self.makePair(atom, self.state.interned_atoms);
        try self.atom_index.put(self.gpa, std.mem.span(atom.as.atom), atom);
        return atom;
    }

    pub fn car(obj: *Object) Error!*Object {
        if (obj.tag != .pair) return error.CarOfNonPair;
        return obj.as.pair.car;
    }

    pub fn cdr(obj: *Object) Error!*Object {
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

    fn isWhitespace(c: u8) bool {
        return c == ' ' or c == '\t' or c == '\n';
    }

    fn isDirective(c: u8) bool {
        return c == '\'' or c == '^' or c == '$';
    }

    fn isPunctuation(c: u8) bool {
        return c == 0 or isWhitespace(c) or isDirective(c) or c == '(' or c == ')' or c == ';';
    }

    fn skipWhitespaceAndComments(self: *Interp) void {
        while (true) {
            const c = self.peek();
            if (isWhitespace(c)) {
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

    /// Reads one object. Nested lists are kept on `open_lists` rather than
    /// the native stack, so nesting depth is limited only by memory.
    fn read(self: *Interp) Error!*Object {
        self.open_lists.clearRetainingCapacity();
        while (true) {
            // Queued objects from ^ or $ always belong to the current list.
            if (self.open_lists.items.len > 0 and self.state.read_stack == self.state.nil) {
                self.skipWhitespaceAndComments();
                if (self.peek() == ')') {
                    self.advance();
                    const list = self.open_lists.pop().?;
                    if (try self.addToList(list.head)) |obj| return obj;
                    continue;
                }
            }
            const obj = try self.readItem() orelse continue; // a list was opened
            if (try self.addToList(obj)) |done| return done;
        }
    }

    /// Reads an atom, number or directive, or opens a list and returns null.
    fn readItem(self: *Interp) Error!?*Object {
        const queued = self.state.read_stack;
        if (queued != self.state.nil) {
            self.state.read_stack = try cdr(queued);
            return try car(queued);
        }

        self.skipWhitespaceAndComments();
        const c = self.peek();
        switch (c) {
            0 => return if (self.open_lists.items.len > 0) error.UnclosedList else error.EndOfInput,
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
                try self.open_lists.append(self.gpa, .{ .head = self.state.nil, .tail = null, .pos = self.state.input_pos });
                self.advance();
                return null;
            },
            else => return try self.readScalar(),
        }
    }

    /// Appends `obj` to the innermost open list, or returns it when no list is open.
    fn addToList(self: *Interp, obj: *Object) Error!?*Object {
        const list = if (self.open_lists.items.len > 0) &self.open_lists.items[self.open_lists.items.len - 1] else return obj;
        const cell = try self.makePair(obj, self.state.nil);
        if (list.tail) |last| last.as.pair.cdr = cell else list.head = cell;
        list.tail = cell;
        return null;
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

    fn print(self: *Interp, obj: *Object) Error!void {
        try self.printObject(obj);
        try self.out.writeByte('\n');
    }

    /// Prints `obj`, with pending work on `print_tasks` as a buffer.
    fn printObject(self: *Interp, obj: *Object) Error!void {
        const w = self.out;
        const nil = self.state.nil;
        const tasks = &self.print_tasks;
        tasks.clearRetainingCapacity();
        try tasks.append(self.gpa, .{ .object = obj });
        while (tasks.pop()) |task| switch (task) {
            .object => |o| {
                if (o == nil) {
                    try w.writeAll("()");
                    continue;
                }
                switch (o.tag) {
                    .atom => try w.writeAll(std.mem.span(o.as.atom)),
                    .num => try w.print("{d}", .{o.as.num}),
                    .pair => {
                        try w.writeByte('(');
                        try tasks.append(self.gpa, .{ .rest = o.as.pair.cdr });
                        try tasks.append(self.gpa, .{ .object = o.as.pair.car });
                    },
                    .clos => {
                        try w.writeAll("CLOSURE<");
                        try tasks.append(self.gpa, .{ .closure_env = o.as.clos.env });
                        try tasks.append(self.gpa, .{ .object = o.as.clos.body });
                    },
                    .prim => try w.print("PRIM<0x{x}>", .{if (o.as.prim < self.primitives.len)
                        @intFromPtr(self.primitives[o.as.prim].func)
                    else
                        o.as.prim}),
                    .nil, _ => {},
                }
            },
            .rest => |rest| {
                if (rest == nil) {
                    try w.writeByte(')');
                } else if (rest.tag != .pair) {
                    try w.writeAll(" . ");
                    try tasks.append(self.gpa, .close);
                    try tasks.append(self.gpa, .{ .object = rest });
                } else {
                    try w.writeByte(' ');
                    try tasks.append(self.gpa, .{ .rest = rest.as.pair.cdr });
                    try tasks.append(self.gpa, .{ .object = rest.as.pair.car });
                }
            },
            .close => try w.writeByte(')'),
            .closure_env => |env| try w.print(", 0x{x}>", .{@intFromPtr(env)}),
        };
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

    pub fn push(self: *Interp, obj: *Object) Allocator.Error!void {
        self.state.stack = try self.makePair(obj, self.state.stack);
    }

    pub fn pop(self: *Interp) Error!*Object {
        const stack = self.state.stack;
        if (stack == self.state.nil) return error.StackUnderflow;
        self.state.stack = try cdr(stack);
        return car(stack);
    }

    /// Runs `comp` in `env` to completion and returns the environment it
    /// ended with. Closure calls push frames on `frames` instead of
    /// recursing, so only memory limits how deep programs go.
    fn compute(self: *Interp, comp: *Object, env: *Object) Error!*Object {
        const base = self.frames.items.len;
        try self.enter(comp, env, null);
        while (true) {
            const top = &self.frames.items[self.frames.items.len - 1];
            if (top.comp == self.state.nil) {
                const done = self.frames.pop().?;
                if (self.frames.items.len == base) return done.env;
                continue;
            }
            const cmd = try car(top.comp);
            top.comp = try cdr(top.comp);
            if (cmd == self.state.atom_quote) {
                if (top.comp == self.state.nil) return error.QuoteWithoutData;
                try self.push(try car(top.comp));
                top.comp = try cdr(top.comp);
                continue;
            }
            // atoms and (...) get ordinary eval
            try self.eval(cmd, base);
        }
    }

    /// Starts running `comp` in `env`.
    fn enter(self: *Interp, comp: *Object, env: *Object, name: ?*Object) Error!void {
        if (self.options.trace) {
            try self.out.writeAll("compute: ");
            try self.print(comp);
        }
        if (self.frames.items.len >= self.options.max_depth) return error.RecursionTooDeep;
        try self.frames.append(self.gpa, .{ .comp = comp, .env = env, .name = name });
    }

    /// Evaluates `expr` in the top frame. `base` is the frame `compute`
    /// started, which is never replaced, so its final environment survives.
    fn eval(self: *Interp, expr: *Object, base: usize) Error!void {
        if (self.options.trace) {
            try self.out.writeAll("eval: ");
            try self.print(expr);
        }
        const index = self.frames.items.len - 1;
        const top = &self.frames.items[index];
        switch (expr.tag) {
            .atom => {
                const val = try self.envFind(top.env, expr);
                switch (val.tag) {
                    .clos => {
                        // A call that ends its body replaces the frame: a tail call.
                        if (top.comp == self.state.nil and index > base) _ = self.frames.pop();
                        try self.enter(val.as.clos.body, val.as.clos.env, expr);
                    },
                    .prim => {
                        // The primitive gets a copy, as a host primitive that
                        // re-enters the interpreter can move `frames`.
                        var env = top.env;
                        try self.primitives[val.as.prim].func(self, &env);
                        self.frames.items[index].env = env;
                    },
                    else => try self.push(val),
                }
            },
            .nil, .pair => try self.push(try self.makeClos(expr, top.env)),
            else => try self.push(expr),
        }
    }
};

/// A list being read.
const OpenList = struct {
    head: *Object,
    tail: ?*Object,
    /// Input position of its `(`.
    pos: usize,
};

/// Printing still to do, innermost last.
const PrintTask = union(enum) {
    object: *Object,
    /// The rest of a list after an element: more elements, a dotted tail, or `)`.
    rest: *Object,
    close,
    closure_env: *Object,
};

/// A closure call in progress.
const Frame = struct {
    /// The commands of the body still to run.
    comp: *Object,
    env: *Object,
    /// The atom the closure was called by; null for the body `compute` started.
    name: ?*Object,
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
    var interp: Interp = try .init(arena, source, &out.writer, .{});
    try interp.run();
    return out.written();
}

fn expectOutput(source: []const u8, expected: []const u8) !void {
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
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const out = try runProgram(arena.allocator(), "((1 x) print)");
    try testing.expectStringStartsWith(out, "CLOSURE<(1 x), 0x");
    try testing.expectStringEndsWith(out, ">\n");
}

test "print: primitives show an address" {
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
    try expectFailure("(1 2", error.UnclosedList);
}

test "failure: empty program" {
    try expectFailure(" ; nothing\n", error.EndOfInput);
}

const countdown_prelude =
    \\($x x) $force
    \\(force cswap $_ force) $if
    \\($f $t $c $fn ^f ^t ^c fn) $endif
    \\() $[ () $]
    \\($f ($x (^x x) f) ($x (^x x) f) force) $Y
    \\($g (^g Y)) $rec
    \\($self $n ^if [ ^n 0 eq 0 ] ([ ^n 1 - ] self) endif) rec $count
;

test "calls: a loop written with tail calls does not grow the native stack" {
    try expectOutput("(" ++ countdown_prelude ++ " 100000 count print)", "0\n");
}

test "calls: recursion deeper than max_depth fails cleanly" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var out: Writer.Allocating = .init(arena.allocator());
    // g calls itself and then pushes 1, so the call is not a tail call.
    var interp: Interp = try .init(arena.allocator(), "(($f ^f f 1) $g ^g g)", &out.writer, .{ .max_depth = 1000 });
    try testing.expectError(error.RecursionTooDeep, interp.run());
    try testing.expectEqual(1000, interp.frames.items.len);
}

test "read and print: lists nested a million deep" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const depth = 1_000_000;
    const nested = try arena.allocator().alloc(u8, 2 * depth);
    @memset(nested[0..depth], '(');
    @memset(nested[depth..], ')');
    const source = try std.mem.concat(arena.allocator(), u8, &.{ "('", nested, " print)" });
    const expected = try std.mem.concat(arena.allocator(), u8, &.{ nested, "\n" });
    try expectOutput(source, expected);
}

test "trace: prints compute and eval lines in forsp.c's order" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var out: Writer.Allocating = .init(arena.allocator());
    var interp: Interp = try .init(arena.allocator(), "(1 $x ('a) $f f ^x print)", &out.writer, .{ .trace = true });
    try interp.run();
    try testing.expectEqualStrings(
        \\compute: (1 quote x pop (quote a) quote f pop f quote x push print)
        \\eval: 1
        \\eval: pop
        \\eval: (quote a)
        \\eval: pop
        \\eval: f
        \\compute: (quote a)
        \\eval: push
        \\eval: print
        \\1
        \\
    , out.written());
}

fn hostIncrement(interp: *Interp, _: **Object) Error!void {
    const n = try interp.pop();
    if (n.tag != .num) return interp.fail("inc expects a number");
    try interp.push(try interp.makeNum(n.as.num + 1));
}

const host_primitives = [_]Primitive{.{ .name = "inc", .func = hostIncrement }};

test "embedding: host primitives run alongside the built-in ones" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var out: Writer.Allocating = .init(arena.allocator());
    var interp: Interp = try .init(arena.allocator(), "(41 inc print 'inc push tag print)", &out.writer, .{ .primitives = &host_primitives });
    try interp.run();
    try testing.expectEqualStrings("42\n5\n", out.written());
}

test "embedding: a host primitive can fail with its own message" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var out: Writer.Allocating = .init(arena.allocator());
    var interp: Interp = try .init(arena.allocator(), "('a inc)", &out.writer, .{ .primitives = &host_primitives });
    const err = interp.run();
    try testing.expectError(error.PrimitiveFailed, err);
    var msg: Writer.Allocating = .init(arena.allocator());
    try interp.writeFailure(error.PrimitiveFailed, &msg.writer);
    try testing.expectEqualStrings("FAIL: inc expects a number\n", msg.written());
}

test "embedding: evalBody keeps definitions and the stack between calls" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var out: Writer.Allocating = .init(arena.allocator());
    var interp: Interp = try .init(arena.allocator(), "", &out.writer, .{});
    try interp.evalBody("5 $x");
    try interp.evalBody("^x ^x * print 7");
    try interp.evalBody("print");
    // Ending with a call (a tail call) still keeps the definitions made before it.
    try interp.evalBody("(1 print) $one 2 $two one");
    try interp.evalBody("^two print");
    try testing.expectEqualStrings("25\n7\n1\n2\n", out.written());
}

/// Runs `source` with `options`, expects it to fail, and returns the diagnostic.
fn failureText(arena: Allocator, source: []const u8, options: Options) ![]u8 {
    var out: Writer.Allocating = .init(arena);
    var interp: Interp = try .init(arena, source, &out.writer, options);
    interp.run() catch |err| {
        var msg: Writer.Allocating = .init(arena);
        try interp.writeFailure(err, &msg.writer);
        return msg.written();
    };
    return error.TestUnexpectedSuccess;
}

test "diagnostics: an unclosed list names where its ( is" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings(
        \\FAIL: End of input: could not read()
        \\  unclosed '(' at line 2, column 3
        \\
    , try failureText(arena.allocator(), "(1\n  (2 3\n", .{}));
}

test "diagnostics: a failure names the closures being run, innermost first" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings(
        \\FAIL: Failed to find in key='nope' in environment
        \\  in: inner <- outer
        \\
    , try failureText(arena.allocator(), "((nope 1) $inner (inner 1) $outer outer)", .{}));
}

test "diagnostics: a tail call replaces its caller in the chain" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings(
        \\FAIL: Failed to find in key='nope' in environment
        \\  in: inner
        \\
    , try failureText(arena.allocator(), "((nope 1) $inner (inner) $outer outer)", .{}));
}

test "diagnostics: a long chain shows the innermost ten closures" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings(
        \\FAIL: Recursion too deep
        \\  in: f <- f <- f <- f <- f <- f <- f <- f <- f <- f <- ... (4 more)
        \\
        // g is called once by name, then calls itself through the name f.
    , try failureText(arena.allocator(), "(($f ^f f 1) $g ^g g)", .{ .max_depth = 15 }));
}

test "diagnostics: a failure at the top level has no chain" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings(
        "FAIL: Value Stack Underflow\n",
        try failureText(arena.allocator(), "(print)", .{}),
    );
}

test "fuzz: printing what was read reads back to the same text" {
    try testing.fuzz({}, fuzzReadPrint, .{ .corpus = &.{
        "(1 (2 3) x)",
        "('a ^b $c)",
        "((((",
        "))",
        "(12abc -0 00 +5 -)",
        "; comment\n(a\tb\rc)",
        "(1 2 . 3)",
    } });
}

fn fuzzReadPrint(_: void, smith: *testing.Smith) !void {
    var buffer: [256]u8 = undefined;
    const len = smith.sliceWeightedBytes(&buffer, &.{
        .rangeAtMost(u8, 0x00, 0xff, 1),
        .rangeAtMost(u8, 'a', 'e', 4),
        .rangeAtMost(u8, '0', '9', 4),
        .value(u8, '(', 8),
        .value(u8, ')', 8),
        .value(u8, ' ', 6),
        .value(u8, '\n', 2),
        .value(u8, '\'', 3),
        .value(u8, '^', 3),
        .value(u8, '$', 3),
        .value(u8, ';', 2),
        .value(u8, '-', 2),
    });
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const first = try readAndPrint(arena.allocator(), buffer[0..len]) orelse return;
    // An empty atom (from a directive or `)` with no name) prints as nothing,
    // so its text cannot read back.
    if (first.has_empty_atom) return;
    const second = try readAndPrint(arena.allocator(), first.text) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings(first.text, second.text);
}

/// Reads the first object of `input` and prints it, or null if the input has none.
fn readAndPrint(arena: Allocator, input: []const u8) !?struct { text: []const u8, has_empty_atom: bool } {
    var out: Writer.Allocating = .init(arena);
    var interp: Interp = try .init(arena, input, &out.writer, .{});
    const obj = interp.read() catch |err| switch (err) {
        error.EndOfInput, error.UnclosedList => return null,
        else => return err,
    };
    try interp.printObject(obj);
    return .{ .text = out.written(), .has_empty_atom = hasEmptyAtom(&interp, obj) };
}

fn hasEmptyAtom(interp: *Interp, obj: *Object) bool {
    return switch (obj.tag) {
        .atom => obj.as.atom[0] == 0,
        .pair => obj != interp.state.nil and
            (hasEmptyAtom(interp, obj.as.pair.car) or hasEmptyAtom(interp, obj.as.pair.cdr)),
        else => false,
    };
}

test "intern: one atom per name, and every atom stays on interned_atoms" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var out: Writer.Allocating = .init(arena.allocator());
    var interp: Interp = try .init(arena.allocator(), "", &out.writer, .{});
    const a = try interp.intern("alpha");
    try testing.expectEqual(a, try interp.intern("alpha"));
    try testing.expect(a != try interp.intern("beta"));
    try testing.expectEqual(a, try interp.intern("alpha"));

    var names: usize = 0;
    var found = false;
    var list = interp.state.interned_atoms;
    while (list != interp.state.nil) : (list = list.as.pair.cdr) {
        names += 1;
        if (list.as.pair.car == a) found = true;
    }
    try testing.expect(found);
    // The built-in names (t, quote, and the primitives) plus alpha and beta.
    try testing.expectEqual(2 + builtins.len + 2, names);
}

test "embedding: evalBody reads a stray ) as the empty atom, as file mode does" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var out: Writer.Allocating = .init(arena.allocator());
    var interp: Interp = try .init(arena.allocator(), "", &out.writer, .{ .max_depth = 100 });
    try testing.expectError(error.UnboundAtom, interp.evalBody("1 print )"));
    try testing.expectEqualStrings("", std.mem.span(interp.unbound.?.as.atom));
    try testing.expectError(error.UnboundAtom, interp.evalBody("^)"));
    try testing.expectEqualStrings("1\n", out.written());
}

test "embedding: evalBody keeps definitions made before a failure" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var out: Writer.Allocating = .init(arena.allocator());
    var interp: Interp = try .init(arena.allocator(), "", &out.writer, .{});
    try testing.expectError(error.UnboundAtom, interp.evalBody("5 $x nope"));
    try interp.evalBody("^x print");
    try testing.expectEqualStrings("5\n", out.written());
}

test "golden: every example prints what forsp.c prints" {
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
