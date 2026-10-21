# /// script
# requires-python = ">=3.11"
# ///
# Copyright (c) 2024 Anthony Bonkoski & Alex Blandin. MIT License; see LICENSE.
"""Differential test: run random programs through forsp.c and the Zig port.

Build both first (`zig build install cref`), then run
`uv run tests/diff.py [--count N] [--seed S]`.

Both must print the same stdout, with addresses replaced. When both fail,
the first line of stderr must match too. Programs that time out in either,
or that crash forsp.c without a message (deep recursion, for one), are
skipped, as are the shift primitives: forsp.c leaves out-of-range shifts
undefined where the port saturates.

forsp.c runs under `stdbuf -o0`, because it aborts on failure and would
lose output still in its buffer. Popping an empty stack fails in forsp.c
with its car() message, which the port reports as a stack underflow.
"""

import argparse
import random
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import NamedTuple

ROOT = Path(__file__).resolve().parent.parent
ZIG = ROOT / "zig-out" / "bin" / "forsp"
C = ROOT / "zig-out" / "bin" / "forsp-c"
TIMEOUT_SECONDS = 5
SHOWN_MISMATCHES = 5
ADDRESS = re.compile(rb"0x[0-9a-f]+>")
UNDERFLOW = (b"FAIL: Value Stack Underflow", b"FAIL: Expected pair to apply car() function")

NAMES = ["a", "b", "c", "f", "g"]
ATOMS = [*NAMES, "x", "y", "t", "quote"]
PRIMS = ["cons", "car", "cdr", "eq", "cswap", "tag", "print", "stack", "env", "-", "*", "nand"]

# How often each kind of command appears in a generated body.
COMMAND_WEIGHTS = {
  "number": 20,
  "quoted": 10,
  "prim": 25,
  "pop": 10,
  "push": 13,
  "call": 10,
  "read": 2,
  "closure": 10,
}


class Outcome(NamedTuple):
  """What one interpreter did with a program."""

  code: int
  stdout: bytes
  stderr: bytes


def datum(rng: random.Random, depth: int) -> str:
  """Returns a quotable datum: a number, an atom, or a list of data."""
  kind = rng.choices(["number", "atom", "list"], weights=[4, 3, 0 if depth <= 0 else 3])[0]
  if kind == "number":
    return str(rng.randint(-3, 20))
  if kind == "atom":
    return rng.choice(ATOMS)
  return "(" + " ".join(datum(rng, depth - 1) for _ in range(rng.randint(0, 4))) + ")"


def body(rng: random.Random, depth: int, length: int) -> str:
  """Returns `length` random commands separated by spaces."""
  return " ".join(command(rng, depth) for _ in range(length))


def command(rng: random.Random, depth: int) -> str:
  """Returns one random command; closures nest at most `depth` deep."""
  kind = rng.choices(list(COMMAND_WEIGHTS), weights=list(COMMAND_WEIGHTS.values()))[0]
  generators = {
    "number": lambda: str(rng.randint(-3, 20)),
    "quoted": lambda: "'" + datum(rng, 2),
    "prim": lambda: rng.choice(PRIMS),
    "pop": lambda: "$" + rng.choice(NAMES),
    "push": lambda: "^" + rng.choice(NAMES),
    "call": lambda: rng.choice(NAMES),  # a call when the name is bound to a closure
    "read": lambda: "read",
    "closure": lambda: "(" + body(rng, depth - 1, rng.randint(0, 6)) + ")" if depth > 0 else "print",
  }
  return generators[kind]()


def binding(rng: random.Random, name: str) -> str:
  """Binds `name` to a closure or a number, evenly."""
  if rng.getrandbits(1):
    return f"({body(rng, 1, rng.randint(1, 5))}) ${name}"
  return f"{rng.randint(0, 9)} ${name}"


def program(rng: random.Random) -> str:
  """Returns a program followed by data for the `read` primitive."""
  # Bind every name first so more programs get past the first lookup.
  prelude = " ".join(binding(rng, name) for name in NAMES)
  trailing = " ".join(datum(rng, 2) for _ in range(rng.randint(0, 3)))
  return f"({prelude} {body(rng, 3, rng.randint(3, 25))})\n{trailing}\n"


def run(command_line: list[str], path: Path) -> Outcome | None:
  """Runs an interpreter on `path`; None if it timed out."""
  try:
    # The command line is built from fixed paths, never from input.
    result = subprocess.run(  # noqa: S603
      [*command_line, str(path)],
      capture_output=True,
      timeout=TIMEOUT_SECONDS,
      check=False,
    )
  except subprocess.TimeoutExpired:
    return None
  return Outcome(result.returncode, ADDRESS.sub(b"0xADDR>", result.stdout), result.stderr)


def first_line(stderr: bytes) -> bytes:
  """Returns the first line of `stderr`."""
  return stderr.split(b"\n", 1)[0]


def compare(source: str, path: Path, stdbuf: str) -> str:
  """Returns 'same', 'same-ok' (both ran to the end), 'skip' or a description of the mismatch."""
  path.write_text(source)
  zig, c = run([str(ZIG)], path), run([stdbuf, "-o0", str(C)], path)
  if zig is None or c is None:
    return "skip"
  if c.code != 0 and not c.stderr.startswith(b"FAIL: "):
    return "skip"  # forsp.c crashed without a message
  if (zig.code == 0) != (c.code == 0):
    return f"exit status: zig {zig.code}, c {c.code}"
  if zig.stdout != c.stdout:
    return "stdout differs"
  lines = (first_line(zig.stderr), first_line(c.stderr))
  if c.code != 0 and lines != UNDERFLOW and lines[0] != lines[1]:
    return f"stderr differs: zig {lines[0]!r}, c {lines[1]!r}"
  return "same-ok" if c.code == 0 else "same"


def main() -> None:
  """Compares the interpreters on `--count` programs and exits 1 on any mismatch."""
  parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
  parser.add_argument("--count", type=int, default=500)
  parser.add_argument("--seed", type=int, default=1)
  args = parser.parse_args()
  for exe in (ZIG, C):
    if not exe.exists():
      sys.exit(f"missing {exe}: run `zig build install cref` first")
  stdbuf = shutil.which("stdbuf") or sys.exit("missing stdbuf (GNU coreutils)")

  rng = random.Random(args.seed)  # noqa: S311 - seeded for reproducible programs, not for secrecy
  tally = {"same": 0, "same-ok": 0, "skip": 0, "mismatch": 0}
  with tempfile.TemporaryDirectory() as tmp:
    path = Path(tmp) / "program.fp"
    for index in range(args.count):
      source = program(rng)
      verdict = compare(source, path, stdbuf)
      if verdict in tally:
        tally[verdict] += 1
        continue
      tally["mismatch"] += 1
      if tally["mismatch"] <= SHOWN_MISMATCHES:
        sys.stdout.write(f"--- program {index} (seed {args.seed}): {verdict}\n{source}\n")
  same = tally["same"] + tally["same-ok"]
  sys.stdout.write(
    f"{args.count} programs: {same} same ({tally['same-ok']} ran to the end, {tally['same']} failed alike), "
    f"{tally['skip']} skipped, {tally['mismatch']} mismatched\n",
  )
  sys.exit(1 if tally["mismatch"] else 0)


if __name__ == "__main__":
  main()
