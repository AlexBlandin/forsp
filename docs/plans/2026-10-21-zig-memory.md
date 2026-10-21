# Zig interpreter memory plan (placeholder)

Goal: decide how the Zig interpreter should reclaim and economise on memory, then plan that work.

Status: placeholder. Nothing here is approved; each item is a question to investigate and answer before a spec is written.

Spec: none yet. Follows `docs/specs/2026-10-21-zig-interpreter-improvements.md`, whose explicit frame stack gives a collector its roots.

## Questions to investigate

- [ ] **Q1 Baseline** - How much does memory grow per step for the `tests/bench/` programs and the examples? Record peak RSS alongside `zig build bench` times, so later changes have a before and after.
  - First data point (ReleaseFast, after the explicit call stack): `tests/bench/countdown.fp` at 100k, 300k and 1M steps uses 126 MB, 378 MB and 1259 MB. User time is linear (0.26 s, 0.72 s, 2.45 s), but system time is not (0.05 s, 0.89 s, 4.82 s), so past a few hundred MB most of the run is the kernel supplying fresh pages.
- [ ] **Q2 Collector** - Can a non-moving mark-and-sweep collector work, with the interpreter state, the value stack, the frame stack and the reader's queue as roots?
  - Objects must not move, because `ptr-from-obj!` hands out addresses as numbers.
  - What rule covers objects a program reaches only through a number (`ptr-to-obj!`)? Options: no collection while `lowlevel` is on, a conservative scan, or a documented "unsafe" rule.
  - When does it run (allocation count, bytes), and how is it tested (a stress mode that collects on every allocation)?
- [ ] **Q3 Small numbers** - Would preallocating common numbers save enough allocations to matter? `ptr-write!` on a shared number would change it everywhere, so this needs `lowlevel` off or copy-on-write.
- [ ] **Q4 Atom names** - Atom names are copied into the arena; can they point into the input instead, given the input outlives the interpreter in file mode but not in the REPL?
- [ ] **Q5 Internal stacks** - The frame, reader and printer stacks grow inside the arena, which cannot free the buffers they outgrow. Should they use a separate allocator that can free?
- [ ] **Q6 Allocator shape** - Is a pool of fixed 24-byte `Object` slots (with a free list for the collector) better than the arena for speed and peak memory?
- [ ] **Q7 REPL lifetime** - In a long REPL session everything allocated stays; what does the collector need to free between lines?

## Rulings

None yet.
