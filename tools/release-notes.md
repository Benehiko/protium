
---

## What is in this download

One archive, `protium-@VERSION@-macos-aarch64.tar.gz`, for Apple silicon Macs.
It holds the `protium` binary and its licence texts. It does **not** hold Wine
or D3DMetal: `protium build` builds Wine on your Mac from CodeWeavers' published
sources, and D3DMetal comes from Apple's Game Porting Toolkit, which you
download yourself (see the README).

## Verifying this download

Every release is signed by the GitHub Actions workflow that built it. The
signature covers `SHA256SUMS`, which pins the archive by hash, and travels
beside it as `SHA256SUMS.sigstore.json`. Download the archive, `SHA256SUMS` and
`SHA256SUMS.sigstore.json` into one directory, then run these two steps from
it, **in this order**.

**1. Check the signature over the checksums.** Install
[cosign](https://docs.sigstore.dev/cosign/system_config/installation/)
(`brew install cosign`), then:

```sh
cosign verify-blob SHA256SUMS \
  --bundle SHA256SUMS.sigstore.json \
  --certificate-identity @COSIGN_IDENTITY@ \
  --certificate-oidc-issuer @COSIGN_ISSUER@
```

It must print `Verified OK`. Anything else means `SHA256SUMS` was not signed by
the release workflow for this tag: stop, and do not run anything from the
download.

The identity is the workflow file in this repository at this tag, and the
issuer is GitHub Actions. There is no person's key or account behind it, and
the signature is recorded in Sigstore's public transparency log.

**2. Check the archive against the checksums.**

```sh
shasum -a 256 -c SHA256SUMS
```

The archive must be listed as `OK`.

Step 1 is what makes step 2 mean anything: checksums downloaded from the same
page as the archive only prove the two agree, not that either came from us.

## Installing

Once both checks pass:

```sh
tar -xzf protium-@VERSION@-macos-aarch64.tar.gz
sudo install -m 755 protium-@VERSION@-macos-aarch64/protium /usr/local/bin/protium
protium version
```

Any directory on your `PATH` will do in place of `/usr/local/bin`; without
`sudo`, `~/.local/bin` works if it is on your `PATH`.

Then let protium tell you what is left to do:

```sh
protium doctor   # does this Mac have what building Wine needs?
protium build    # build Wine from CodeWeavers' sources
protium status   # where the installation is, and the next step
```

The README covers D3DMetal, which comes from Apple, and `protium shell-init`
prints the line that makes prefixes automatic in every new terminal.

## "cannot be opened" or "Apple could not verify"

`protium` is signed ad hoc, not with an Apple Developer ID, and is not
notarized. A web browser marks what it downloads as quarantined, and macOS
refuses to run a quarantined binary it cannot trace to a registered developer.
The message reads *"protium" cannot be opened because the developer cannot be
verified*, or, on macOS 15 and later, *Apple could not verify "protium" is free
of malware*.

**Verify the download first (above)**, then clear the quarantine from the
unpacked directory, before installing:

```sh
tar -xzf protium-@VERSION@-macos-aarch64.tar.gz
xattr -dr com.apple.quarantine protium-@VERSION@-macos-aarch64
```

Or, after the first refusal: System Settings → Privacy & Security → scroll to
the message about `protium` → **Open Anyway**.

Downloads made with `curl` or `gh release download` are not quarantined and
need neither step.
