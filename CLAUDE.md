# Working rules for this repository

## The language is Zig. Do not write Python.

Everything here is Zig: it builds, it is tested (`zig build test`), it is
formatted (`zig fmt`, enforced by the pre-commit hook). A Python script has
none of that — it is not covered by the build, not run by CI, not checked by
the formatter, and it re-implements logic the program already has, which then
drifts from the code it is supposed to be checking.

**Do not add a `.py` file to this repository.** Not to `tools/`, not as a
scratch script that "will be deleted later", not to parse a binary. Shell is
acceptable only inside `.githooks/` and CI, where it dispatches to Zig.

## This repository assembles other people's software. Verify, do not assume.

The whole point of protium is that the environment is understood rather than
taken on trust. Two rules follow:

* **A claim about Apple's redistributable or CrossOver's sources belongs in
  `docs/` with the evidence that produced it** — the file listing, the
  `lipo -archs` output, the configure line. A claim without its evidence is
  the thing this project exists to replace.
* **Record versions, always.** "D3DMetal" is not a fact; "D3DMetal 4.0b2,
  `CFBundleShortVersionString` from the framework's Info.plist" is. The same
  goes for Wine: the tree is CrossOver 26.3.0's, which is `wine-11.0`.

## Gotchas that have cost real time

* **Verify a green build properly.** `zig build test; echo $?`. Reading a
  task's exit code is not enough when the command was a pipeline — the exit
  belongs to the last stage, which is usually a `tail`. Echo the status of the
  step you care about, explicitly.
* **A passing test must not print.** Zig's test runner multiplexes stdout; a
  `std.debug.print` from a passing test corrupts the stream and the run reports
  a failure with no failing test. Print only on failure.
* **A `test {}` block gates which files are tested.** A `pub const` import
  alone leaves a file's tests uncompiled. Add new files to the `test {}` block
  in `src/root.zig`, and watch the test *count*, not just the exit code.
* **Do not install build dependencies on the host.** Everything the Wine
  recipe needs — a modern bison, a PE toolchain, an x86-64 FreeType — is
  fetched into a scratch directory. The recipe in `docs/wine-build.md` assumes
  nothing is installed system-wide, and it should stay that way.

## Commits

Conventional prefixes (`feat:`, `fix:`, `refactor:`, `docs:`, `test:`,
`perf:`). Commit directly to `main` — no feature branches. Code, tests and docs
for one change go in one commit. Run `zig fmt` before committing; the
pre-commit hook rejects unformatted files and will not re-stage them for you.
