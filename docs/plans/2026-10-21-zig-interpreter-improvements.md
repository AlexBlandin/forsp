# Zig interpreter improvements plan

Goal: implement the spec in one session, task by task, each task a red-green change and its own commit.

Spec: `docs/specs/2026-10-21-zig-interpreter-improvements.md`.

Conventions: `zig build test` and `zig fmt --check build.zig build.zig.zon src/` pass after every task; the golden examples stay byte-identical.

## Tasks

- [x] **T1 Benchmark** - tier: sonnet - depends: none
  Goal: measure before changing the evaluator.
  Owns: src/bench.zig, tests/bench/, build.zig
  Produces: `zig build bench`
  Acceptance: `zig build bench -Doptimize=ReleaseFast` prints a time per program.

- [x] **T2 Explicit call stack, tail calls and depth limit** - tier: opus (evaluator design) - depends: T1
  Goal: R1 (calls) and R2.
  Owns: src/forsp.zig
  Produces: `Options.max_depth`, `error.RecursionTooDeep`
  Acceptance: a 1,000,000-step tail-recursive countdown prints 0; unbounded non-tail recursion fails with `Recursion too deep`; golden tests pass.
  Done: the unit test runs 100,000 steps (Debug is slow); 1,000,000 steps was run by hand with a ReleaseFast build and printed 0. Traces of four examples match the C `DEBUG` build line for line.

- [x] **T3 Iterative reader and printer** - tier: sonnet - depends: T2
  Goal: R1 (reader and printer).
  Owns: src/forsp.zig
  Acceptance: reading and printing a list nested 1,000,000 deep succeeds in a Debug build.

- [x] **T4 Runtime trace and embedding API** - tier: sonnet - depends: T3
  Goal: R4, and the runtime half of R5's tracing.
  Owns: src/forsp.zig, src/main.zig, build.zig
  Produces: `Options`, `Primitive`, `Interp.evalBody`, `Interp.fail`
  Acceptance: tests show a host primitive running, `evalBody` keeping definitions across calls, and trace output matching the C order.

- [x] **T5 Diagnostics** - tier: sonnet - depends: T4
  Goal: R3.
  Owns: src/forsp.zig, build.zig, tests/cli/
  Acceptance: tests show the unclosed-paren position and the closure chain; the first line of each failure is unchanged.

- [x] **T6 CLI** - tier: sonnet - depends: T5
  Goal: R5.
  Owns: src/main.zig, build.zig, tests/cli/, README.md
  Acceptance: CLI checks in `zig build test` cover stdin, `--trace` and `--repl` (definitions persist across lines, a failure does not end the session, a multi-line form works).

- [x] **T7 Fuzzing and differential testing** - tier: sonnet - depends: T6
  Goal: R6 (fuzzing, `cref`, `tests/diff.py`).
  Owns: src/forsp.zig, build.zig, tests/diff.py
  Acceptance: `zig build test` runs the fuzz corpus; a short `zig build test --fuzz` run finds no crash; `tests/diff.py` reports no mismatches over 500 programs.

- [x] **T8 Interning hash index** - tier: sonnet - depends: T7
  Goal: R7.
  Owns: src/forsp.zig, tests/bench/
  Acceptance: golden tests pass; `zig build bench` shows the atom-heavy program faster than before.

## Rulings

- Ruling: from "8-1 (atom)", item 8.1 (interning hash index) is approved and the small-number cache waits for the memory plan - the reply's parenthesis names the atom item - cost if wrong: one revert of T8.
- Ruling: one plan file with the spec beside it, executed in this session - the tasks share `src/forsp.zig`, so they cannot run in parallel - cost if wrong: none.
- Ruling: the failure detail goes on lines after the C line, always on, rather than behind a flag - the CLI checks pin stderr and the first line is what scripts match - cost if wrong: one flag.
- Ruling: the REPL uses an explicit `--repl` flag, and a bare `forsp` still prints usage - keeps the existing CLI check and C behaviour - cost if wrong: a one-line change.
- Ruling: in `evalBody` the whole chunk is read before it runs, so `read` sees end of input there - running form by form would need the evaluator to pull from the reader - cost if wrong: `read`-driven programs need file mode.
- Ruling: host primitives get a copy of the frame's environment and it is written back afterwards, and they must not call `run` or `evalBody` - a pointer into the frame stack would dangle if a primitive grew it, and both entry points reset it - cost if wrong: none.
- Ruling: the differential harness is Python run by hand with a timeout per program, not part of `zig build test` - random programs can loop for ever and C aborts on failure - cost if wrong: it is not run in CI.
- Ruling: `zig build bench` times in-process with whatever `-Doptimize` is given; numbers are quoted for ReleaseFast - keeps one build graph - cost if wrong: a Debug number gets quoted by mistake.
- Ruling: the REPL exits 1 if any chunk failed, and input that ends inside a list is reported like any failure - scripts piping into `--repl` can see that something went wrong - cost if wrong: one line.
- Ruling: fuzzing is run with `-Doptimize=ReleaseSafe` - the Debug build uses Zig's own backend, and `--fuzz` then stops with "corrupted coverage file: pcs_len was zero" - cost if wrong: none, Debug still runs the corpus.
- Ruling: `tests/diff.py` runs forsp.c under `stdbuf -o0` and accepts the port's `Value Stack Underflow` where forsp.c reports its car() message - forsp.c aborts with output still buffered, and its stack is never NULL, so popping an empty stack fails in car() - cost if wrong: a real car() mismatch on an empty stack is hidden.
