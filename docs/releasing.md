# Releasing protium

Releases are built, signed and published from a Mac, by hand, with `make`.
Nothing is built or signed in CI; CI only checks that the release shape still
builds (`make check-release`).

## What a release is

One archive per supported host — today only `macos-aarch64`, because protium
refuses an Intel Mac (`src/doctor.zig`) — plus `SHA256SUMS` and one signature
over it, `SHA256SUMS.sigstore.json`.

```
protium-v0.1.0-macos-aarch64/
  protium                 ReleaseSafe, stripped, ad-hoc signed by the linker
  README.md
  LICENSE  NOTICE  THIRD-PARTY-NOTICES.md
  patches/                the Wine patches the binary embeds, in source form
  licenses/LGPL-2.1.txt   the patches' licence
  licenses/zig-MIT.txt    Zig's, for the standard library linked in
```

A release never contains Wine or D3DMetal. See
[THIRD-PARTY-NOTICES.md](../THIRD-PARTY-NOTICES.md#what-protium-distributes) for
why each file above is there.

## Once per machine

```sh
brew install cosign gh
gh auth login
```

## Every release

1. Bump `protium_version` in `src/main.zig` and `.version` in `build.zig.zon`,
   commit, and push to `main`. `make package` refuses a `VERSION` that
   disagrees with `src/main.zig`.

2. `make tag VERSION=v0.1.0` — an annotated tag, locally. An editor opens:
   the tag message becomes the release notes, so write them there.

3. `make release VERSION=v0.1.0` — refuses a dirty tree or a HEAD not tagged
   `VERSION`, then runs the tests, builds, packages into `dist/`, and signs.
   A browser opens once: sign in to GitHub and **choose the noreply address**
   (`18033717+Benehiko@users.noreply.github.com`). Whichever address you pick
   goes into the certificate and Sigstore's public transparency log, and the
   release then verifies the signature against `COSIGN_IDENTITY` straight away,
   so picking a different one fails here rather than for a user.

4. Look at `dist/`. Nothing is public yet.

5. `make publish VERSION=v0.1.0` — pushes the tag and creates the GitHub
   release with the archive, `SHA256SUMS` and the bundle. The notes are the
   tag message followed by `tools/release-notes-footer.md`, which tells users
   how to verify the download and get past Gatekeeper.

`make package VERSION=v0.1.0` does step 3 without the tag check and without
signing, for trying the packaging out.

## Choices, and why

* **`-Dtarget=aarch64-macos`, not native.** A native build targets the CPU of
  the machine doing the build; the explicit target builds for the baseline
  every Apple silicon Mac has.
* **ReleaseSafe.** A bounds error becomes a panic with a message instead of
  quietly wrong behaviour in a tool that deletes prefixes.
* **`-Dstrip=true`.** Without it the binary names paths on the build machine.
  It is stripped at link time because running `strip` afterwards would break
  the linker's ad-hoc signature, and Apple silicon will not run an arm64
  binary whose signature does not match.
* **One signature, over `SHA256SUMS`.** The manifest pins every archive, so
  signing it is the same claim as signing each archive.
* **Keyless cosign.** There is no key to keep safe; the certificate records
  who signed and Sigstore's log makes it public.
* **Not notarized.** That needs a paid Apple Developer ID. The footer tells
  users how to clear the quarantine after verifying.

## Signing in CI instead

cosign can sign keyless from a GitHub Actions workflow with `id-token: write`,
and no browser. The identity a user verifies against then becomes the
workflow file, not the maintainer's account, so the footer's verify command
would change with it.
