# Contributing

## Building from source

You need [Zig](https://ziglang.org/download/) 0.16.0 or newer.

```sh
git clone https://github.com/Benehiko/protium
cd protium
zig build --prefix ~/.local -Doptimize=ReleaseFast
```

This installs `~/.local/bin/protium`. A source build reports its version as
`dev`; pass `-Dversion=0.1.0` to set one.

## Making a change

```sh
zig build            # build the binary into zig-out/bin
zig build test       # run the tests
zig fmt .            # format; the pre-commit hook enforces it
```

The pre-commit hook lives in `.githooks/`, so it is tracked and reviewable.
Enable it in each clone with `git config core.hooksPath .githooks`. It checks
formatting and the build, and leaves the tests to CI.
`git commit --no-verify` bypasses it.

[docs/releasing.md](docs/releasing.md) explains how releases are built and
signed.
