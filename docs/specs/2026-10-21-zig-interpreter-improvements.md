# Zig interpreter improvements

Improve `src/forsp.zig` and its CLI without changing what any example prints: every file in `examples/` must still print exactly what `forsp.c` prints.

Memory work (a collector, interning or caching small numbers, other allocation tricks) is out of scope; see `docs/plans/2026-10-21-zig-memory.md`.

## Motivation

A countdown loop of 100,000 steps, written with the `rec`/`if` idiom from `examples/factorial.fp`, segfaults in both the C and the Zig interpreter, because every closure call nests native calls (`compute` -> `eval` -> `compute`). The reader and the printer also recurse on nesting depth, so deep input or deep data can overflow the native stack.

## Requirements

### R1 Calls run on an explicit stack, with tail calls

- `compute` and `eval` keep a stack of frames (remaining body, environment, the atom that named the closure) on the heap instead of recursing.
- A closure call that is the last command of a body replaces the caller's frame instead of adding one, so loops written as tail calls run in constant frame depth.
- Trace output (`compute:`/`eval:` lines) is printed in the same order as `forsp.c`.
- The reader and the printer do not recurse on nesting depth.

### R2 Deep recursion fails cleanly

- More than `Options.max_depth` live frames (default 1,048,576) fails with `FAIL: Recursion too deep`.

### R3 Diagnostics

- The first line of every failure stays exactly as `forsp.c` prints it.
- Further lines add detail:
  - An unclosed `(` at the end of input names the line and column of that `(`.
  - A failure inside named closures names the chain of closures being run, innermost first, at most 10 of them, followed by the number of further frames omitted. Frames replaced by tail calls are not shown.

### R4 Embedding

- `Interp.init` takes `Options`: `trace`, `max_depth` and extra host `primitives`.
- Host primitives use the same signature as the built-in ones and can use the public helpers `push`, `pop`, `makeNum`, `makePair`, `intern`, `car`, `cdr` and `fail` (a failure with a host message).
- `Interp.evalBody(input)` reads every form in `input` and computes them as one body in the top-level environment, keeping definitions and the value stack for the next call.

### R5 CLI

- `forsp [--trace] <path>` runs a file; a path of `-` reads the program from stdin.
- `forsp [--trace] --repl` reads stdin line by line and evaluates each chunk with `evalBody`.
  - A chunk with an unclosed `(` continues on the next line.
  - A failure is reported on stderr and the REPL carries on.
  - Prompts are printed only when stdin is a terminal.
- Tracing is the runtime `--trace` flag; the `-Dtrace` build option is removed.

### R6 Testing and measurement

- The reader and printer are fuzzed with `std.testing.fuzz` (`zig build test --fuzz`); `zig build test` runs the seed corpus.
- `zig build cref` builds `forsp.c` with `zig cc`.
- `tests/diff.py` runs random programs through both interpreters and compares their stdout, and the first line of stderr when both fail; it is run by hand and is not part of `zig build test`.
- `zig build bench` times the programs in `tests/bench/` in-process and prints the results.

### R7 Atom interning uses a hash index

- `intern` looks names up in a hash map kept alongside `interned_atoms`, instead of scanning the list. The list stays, because `ptr-state!` exposes it.
