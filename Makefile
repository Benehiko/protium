.PHONY: build test check-release tag package package-host release publish

# Releases are built, signed and published from a Mac by hand. The steps and
# the reasons behind them are in docs/releasing.md.

build:
	zig build

test:
	zig build test

DIST ?= dist
VERSION ?=

# The version protium prints for `protium version`. A release tag is `v` plus
# this, and `package` refuses anything else: an archive named v0.2.0 holding a
# binary that says 0.1.0 is worse than no release.
SOURCE_VERSION := $(shell sed -n 's/^const protium_version = "\(.*\)";/\1/p' src/main.zig)

# The supported hosts, as `<os>-<arch>`. Apple silicon only: `protium doctor`
# refuses an Intel Mac (src/doctor.zig).
RELEASE_HOSTS ?= macos-aarch64
ZIG_TARGET_macos-aarch64 := aarch64-macos

# This machine as a RELEASE_HOSTS entry. `uname -m` says `arm64` where Zig and
# the archive name say `aarch64`.
NATIVE_HOST := macos-$(patsubst arm64,aarch64,$(shell uname -m))

# The flags every release build uses. `check-release` builds the same way, so
# CI catches a release that would no longer build.
RELEASE_FLAGS = -Doptimize=ReleaseSafe -Dstrip=true

# Zig's own licence, copied into every archive because the standard library is
# linked in and MIT asks for its notice to travel with copies. Taken from the
# toolchain that does the build, so the text matches the code. A tarball
# install keeps it beside `lib/`; Homebrew keeps it two levels up from
# `lib/zig`.
ZIG_LIB := $(shell zig env 2>/dev/null | sed -n 's/.*\.lib_dir = "\(.*\)",/\1/p')
ZIG_LICENSE ?= $(firstword $(wildcard $(ZIG_LIB)/../LICENSE $(ZIG_LIB)/../../LICENSE))

# cosign, for the signature over SHA256SUMS. A host `cosign` wins; otherwise
# the official image under whichever container runtime is here. `-it` because
# keyless signing prints a URL and waits, `--network host` because the OIDC
# callback returns to localhost, `--user 0:0` so a rootless runtime writes the
# bundle as the invoking user.
CONTAINER ?= $(firstword $(foreach c,nerdctl podman docker,$(shell command -v $(c) 2>/dev/null)))
COSIGN ?= $(if $(shell command -v cosign 2>/dev/null),cosign,$(if $(CONTAINER),$(CONTAINER) run --rm -it --network host \
	--user 0:0 -e HOME=/tmp -v "$(CURDIR)/$(DIST)":/work -w /work \
	ghcr.io/sigstore/cosign/cosign:latest))

# The identity a user verifies a release against, written into the release
# notes. The GitHub noreply alias, not a personal address: whichever address
# is picked on GitHub's consent screen goes into the certificate and into
# Sigstore's public, permanent transparency log. It is also the address every
# commit here is authored with.
COSIGN_IDENTITY ?= 18033717+Benehiko@users.noreply.github.com
COSIGN_ISSUER ?= https://github.com/login/oauth

NOTES_FOOTER ?= tools/release-notes-footer.md

# ── make check-release ──────────────────────────────────────────────────
#
# Does the shape we publish still build? Installed under its own prefix so
# zig-out is left alone. CI runs this.
#
# `foreach` rather than a shell loop: the target triple is a make variable
# named after the host, which a shell loop variable cannot look up.
check-release:
	$(foreach host,$(RELEASE_HOSTS),zig build $(RELEASE_FLAGS) -Dtarget=$(ZIG_TARGET_$(host)) \
		--prefix .zig-cache/release-check/$(host) &&) true

# ── make tag ────────────────────────────────────────────────────────────
#
# An annotated tag, locally; `publish` pushes it. An editor opens with a
# one-line message to extend: the tag message becomes the release notes.
tag:
	@test -n "$(VERSION)" || { echo "make tag: set VERSION, e.g. make tag VERSION=v0.1.0" >&2; exit 1; }
	@test "$(VERSION)" = "v$(SOURCE_VERSION)" || { \
		echo "make tag: VERSION is $(VERSION), but src/main.zig says $(SOURCE_VERSION)" >&2; exit 1; }
	@test -z "$$(git status --porcelain)" || { echo "make tag: the tree is dirty -- commit or stash first" >&2; exit 1; }
	@! git rev-parse -q --verify "refs/tags/$(VERSION)" >/dev/null || { \
		echo "make tag: $(VERSION) already exists -- delete it first, or pick another version" >&2; exit 1; }
	git tag -a "$(VERSION)" -e -m "protium $(VERSION)"
	@echo
	@echo "tagged $(VERSION) locally. Not pushed."
	@echo "next: make release VERSION=$(VERSION)"

# ── make package ────────────────────────────────────────────────────────
#
# Test, build and archive into $(DIST), with checksums. No tag check and no
# signature: `release` adds both. Run on its own to try the packaging.
package:
	@test -n "$(VERSION)" || { echo "make package: set VERSION, e.g. make package VERSION=v0.1.0" >&2; exit 1; }
	@test "$(VERSION)" = "v$(SOURCE_VERSION)" || { \
		echo "make package: VERSION is $(VERSION), but src/main.zig says $(SOURCE_VERSION)" >&2; exit 1; }
	@test -n "$(ZIG_LICENSE)" && test -f "$(ZIG_LICENSE)" || { \
		echo "make package: cannot find Zig's LICENSE near $(ZIG_LIB)" >&2; \
		echo "  the standard library is linked in, so its licence must ship -- set ZIG_LICENSE=<path>" >&2; \
		exit 1; }
	rm -rf $(DIST)
	mkdir -p $(DIST)
	@# The tests, once, under the optimiser the release ships.
	zig build test -Doptimize=ReleaseSafe
	@for host in $(RELEASE_HOSTS); do \
		$(MAKE) --no-print-directory package-host VERSION=$(VERSION) HOST=$$host || exit 1; \
	done
	cd $(DIST) && shasum -a 256 *.tar.gz > SHA256SUMS
	@echo
	@cat $(DIST)/SHA256SUMS

# One host's archive. Called by `package`, never directly.
STAGE = $(DIST)/protium-$(VERSION)-$(HOST)
package-host:
	@test -n "$(HOST)" || { echo "package-host: set HOST" >&2; exit 1; }
	@echo
	@echo "--- $(HOST) ---"
	@# An explicit target rather than native, so the binary is built for the
	@# baseline every Apple silicon Mac has, not for this machine's CPU.
	zig build $(RELEASE_FLAGS) -Dtarget=$(ZIG_TARGET_$(HOST)) --prefix $(DIST)/.build-$(HOST)
	mkdir -p $(STAGE)/licenses $(STAGE)/patches
	cp $(DIST)/.build-$(HOST)/bin/protium $(STAGE)/
	cp README.md LICENSE NOTICE THIRD-PARTY-NOTICES.md $(STAGE)/
	@# The patches the binary embeds, in source form, with their licence: they
	@# change Wine and are LGPL-2.1-or-later (patches/README.md).
	cp patches/README.md patches/*.patch $(STAGE)/patches/
	cp licenses/LGPL-2.1.txt $(STAGE)/licenses/LGPL-2.1.txt
	cp "$(ZIG_LICENSE)" $(STAGE)/licenses/zig-MIT.txt
	@# Apple silicon will not run an arm64 binary whose signature is broken.
	codesign --verify --strict $(STAGE)/protium
	@# -Dstrip is what keeps the build machine's paths out; check it did.
	@! grep -qF "$(HOME)" $(STAGE)/protium || { \
		echo "package: the binary contains $(HOME) -- it was not stripped" >&2; exit 1; }
	@if [ "$(HOST)" = "$(NATIVE_HOST)" ]; then \
		reported=$$($(STAGE)/protium version); \
		test "$$reported" = "protium $(SOURCE_VERSION)" || { \
			echo "package: the binary reports '$$reported', not protium $(SOURCE_VERSION)" >&2; exit 1; }; \
		echo "version check: $$reported"; \
	fi
	@# COPYFILE_DISABLE keeps macOS tar from adding ._ AppleDouble files.
	COPYFILE_DISABLE=1 tar -C $(DIST) -czf $(STAGE).tar.gz protium-$(VERSION)-$(HOST)
	rm -rf $(STAGE) $(DIST)/.build-$(HOST)

# ── make release ────────────────────────────────────────────────────────
#
# `package` from a clean, tagged tree, then sign. Publishes nothing: `publish`
# does that, so there is a moment to look at $(DIST) first.
release:
	@test -n "$(VERSION)" || { echo "make release: set VERSION, e.g. make release VERSION=v0.1.0" >&2; exit 1; }
	@test -z "$$(git status --porcelain)" || { echo "make release: the tree is dirty -- commit or stash first" >&2; exit 1; }
	@described=$$(git describe --tags --exact-match 2>/dev/null); \
		test "$$described" = "$(VERSION)" || { \
			echo "make release: HEAD is not tagged $(VERSION) (git describe says '$$described')" >&2; \
			echo "  run: make tag VERSION=$(VERSION)" >&2; \
			exit 1; }
	@test -n "$(COSIGN)" || { \
		echo "make release: no cosign and no container runtime (nerdctl, podman or docker)" >&2; \
		echo "  brew install cosign, or set COSIGN=<command>" >&2; \
		exit 1; }
	$(MAKE) --no-print-directory package VERSION=$(VERSION)
	@echo
	@echo "signing SHA256SUMS with cosign -- a browser opens once."
	@echo "choose $(COSIGN_IDENTITY) on GitHub's consent screen."
	@# One bundle (signature, certificate and transparency-log proof in one
	@# file): cosign 3 refuses the separate .sig and .pem outputs.
	cd $(DIST) && $(COSIGN) sign-blob --yes SHA256SUMS --bundle SHA256SUMS.sigstore.json
	@test -r $(DIST)/SHA256SUMS.sigstore.json || { \
		echo "make release: the signature bundle is not readable by this account" >&2; exit 1; }
	@# Verify exactly as a user will. Signing in with any other address than
	@# COSIGN_IDENTITY fails here rather than on someone else's machine.
	cd $(DIST) && $(COSIGN) verify-blob SHA256SUMS --bundle SHA256SUMS.sigstore.json \
		--certificate-identity "$(COSIGN_IDENTITY)" --certificate-oidc-issuer "$(COSIGN_ISSUER)"
	@echo
	@ls -la $(DIST)
	@echo
	@echo "built and signed. Nothing is published yet."
	@echo "next: make publish VERSION=$(VERSION)"

# ── make publish ────────────────────────────────────────────────────────
#
# Push the tag and create the GitHub release. The one step that cannot be
# quietly undone, so it re-checks what it is about to upload rather than
# trusting that `release` ran.
publish:
	@test -n "$(VERSION)" || { echo "make publish: set VERSION, e.g. make publish VERSION=v0.1.0" >&2; exit 1; }
	@test -f $(DIST)/SHA256SUMS.sigstore.json || { \
		echo "make publish: $(DIST) is not signed -- run make release VERSION=$(VERSION) first" >&2; exit 1; }
	@for host in $(RELEASE_HOSTS); do \
		test -f $(DIST)/protium-$(VERSION)-$$host.tar.gz || { \
			echo "make publish: no $(DIST)/protium-$(VERSION)-$$host.tar.gz" >&2; exit 1; }; \
	done
	cd $(DIST) && shasum -a 256 -c SHA256SUMS
	@test "$$(git rev-parse "$(VERSION)^{commit}" 2>/dev/null)" = "$$(git rev-parse HEAD)" || { \
		echo "make publish: $(VERSION) does not point at HEAD -- $(DIST) may be from another commit" >&2; exit 1; }
	@! gh release view "$(VERSION)" >/dev/null 2>&1 || { \
		echo "make publish: a $(VERSION) release already exists on GitHub" >&2; exit 1; }
	git for-each-ref --format='%(contents:subject)%0a%0a%(contents:body)' "refs/tags/$(VERSION)" > $(DIST)/notes.md
	sed -e 's|@VERSION@|$(VERSION)|g' \
		-e 's|@COSIGN_IDENTITY@|$(COSIGN_IDENTITY)|g' \
		-e 's|@COSIGN_ISSUER@|$(COSIGN_ISSUER)|g' \
		$(NOTES_FOOTER) >> $(DIST)/notes.md
	git push origin "$(VERSION)"
	gh release create "$(VERSION)" --verify-tag --title "protium $(VERSION)" \
		--notes-file $(DIST)/notes.md \
		$(DIST)/protium-$(VERSION)-*.tar.gz $(DIST)/SHA256SUMS $(DIST)/SHA256SUMS.sigstore.json
	@echo
	@echo "published. Users verify against:"
	@echo "  --certificate-identity $(COSIGN_IDENTITY)"
	@echo "  --certificate-oidc-issuer $(COSIGN_ISSUER)"
