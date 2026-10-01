# Releasing protium

A release is built, signed and published by GitHub Actions when a `v*` tag is
pushed (`.github/workflows/release.yml`). The steps live in the `Makefile`, so
the workflow and a person trying the packaging run the same commands.

## What a release is

One protium archive per supported host — today only `macos-aarch64`, because
protium refuses an Intel Mac (`src/doctor.zig`) — the Wine runtime the
`wine-build` workflow built for the release, the source archives that runtime
was built from, and `SHA256SUMS` over all of them with one signature,
`SHA256SUMS.sigstore.json`. The release notes carry how to verify and install
the download.

```
protium-v0.1.0-macos-aarch64/
  protium                 ReleaseSafe, stripped, ad-hoc signed by the linker
  README.md
  LICENSE  NOTICE  THIRD-PARTY-NOTICES.md
  patches/                the Wine patches the binary embeds, in source form
  licenses/LGPL-2.1.txt   the patches' licence
  licenses/zig-MIT.txt    Zig's, for the standard library linked in
```

```
wine-11.0-cx26.3-p2-macos-x86_64.tar.gz
  wine-11.0-cx26.3-p2/    the runtime, as `protium build` installs it
    licenses/             Wine's, the libraries it links in, and the libraries in lib/
crossover-sources-26.3.0.tar.gz  freetype-…  gnutls-…  nettle-…  gmp-…
                          the exact sources the runtime was built from
```

protium is built with the runtime archive's SHA-256 compiled in
(`-Druntime_sha256`, `make package RUNTIME_SHA256=…`), so `protium runtime
install` takes that archive and nothing else. The signature covers protium, and
protium vouches for the runtime.

A release never contains D3DMetal. See
[THIRD-PARTY-NOTICES.md](../THIRD-PARTY-NOTICES.md) for which licence covers
each file above, and why each is there.

## Every release

1. Make sure what you want released is on `main`. There is no version to bump:
   the tag is the version. `make package` passes it to the build as
   `-Dversion=0.1.0` and checks the binary reports it. (`.version` in
   `build.zig.zon` is not used for this; Zig requires it to be a literal.)

2. `make tag VERSION=v0.1.0` — an annotated tag, locally. An editor opens:
   the tag message becomes the release notes, so write them there.

3. `git push origin v0.1.0`. The workflow then:

   1. refuses a tag that is not on `main`;
   2. runs the tests and builds and packages into `dist/` (`make package`);
   3. signs `SHA256SUMS` with cosign, and verifies the signature as a user
      will (`make sign`);
   4. writes the notes (`make notes`): the tag message, then
      `tools/release-notes.md` with the version and identity filled in;
   5. creates the GitHub release with every archive, `SHA256SUMS` and the
      bundle. A tag with a hyphen, such as `v0.2.0-rc1`, becomes a
      pre-release: published, but never marked as the latest release.

4. Watch the run under the repository's Actions tab, then open the release
   and read its notes.

`make package VERSION=v0.1.0` does step 3.2 on a Mac without signing, for
trying the packaging out. `make notes VERSION=v0.1.0` renders the notes into
`dist/` for a tag that exists locally.

## Signing

The signature is keyless, made by the workflow. There is no key and no secret:
the job has `id-token: write`, GitHub gives it a short-lived OIDC token, and
cosign trades that for a certificate that names the workflow. The signature
and certificate go into Sigstore's public transparency log.

What a user verifies against is therefore the workflow, not a person:

```
--certificate-identity https://github.com/Benehiko/protium/.github/workflows/release.yml@refs/tags/v0.1.0
--certificate-oidc-issuer https://token.actions.githubusercontent.com
```

* **Renaming `release.yml` changes the identity**, and with it what every
  later release verifies against. `COSIGN_IDENTITY` in the `Makefile` and the
  notes follow it; a release cut before the rename still verifies against the
  old name.
* **Whoever can push a `v*` tag can publish a release that verifies.** Protect
  the pattern with a tag ruleset (Settings → Rules → Rulesets, target tags,
  pattern `v*`) so only maintainers can create them. The workflow also
  refuses a tag that is not on `main`.
* Signing only works in the workflow. Run anywhere else, `make sign` opens a
  browser and then fails its own verification, because the identity is not the
  workflow's.

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
* **Keyless cosign, as the workflow.** There is no key to keep safe or rotate,
  and no browser step to do by hand; the certificate records which workflow
  at which tag signed, and Sigstore's log makes it public.
* **Not notarized.** That needs a paid Apple Developer ID. The notes tell
  users how to clear the quarantine after verifying.
