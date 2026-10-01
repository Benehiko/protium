.PHONY: build test check-release tag package package-host notes sign verify

# A release is built, signed and published by GitHub Actions when a `v*` tag
# is pushed (.github/workflows/release.yml). This file holds the steps, so the
# workflow and a person trying the packaging run the same commands. The
# reasons are in docs/releasing.md.

build:
	zig build

test:
	zig build test

DIST ?= dist
VERSION ?=

# The version protium prints for `protium version`: the tag without its `v`,
# passed to the build as -Dversion. `package` checks the built binary reports
# it: an archive named v0.2.0 holding a binary that says 0.1.0 is worse than
# no release.
SOURCE_VERSION = $(patsubst v%,%,$(VERSION))

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


# The identity a user verifies a release against, written into the release
# notes. The signature is made keyless by the release workflow, so the
# certificate names that workflow file at the tag it ran for, and GitHub's
# OIDC issuer vouches for it. Change the workflow's file name and this changes
# with it, or every release stops verifying.
REPO ?= Benehiko/protium
COSIGN_IDENTITY ?= https://github.com/$(REPO)/.github/workflows/release.yml@refs/tags/$(VERSION)
COSIGN_ISSUER ?= https://token.actions.githubusercontent.com

# The release notes template: what is in the download, how to verify it, how
# to install it. `notes` fills in the @...@ markers.
NOTES_TEMPLATE ?= tools/release-notes.md

# The notes for each version, newest first, each under a `## vX.Y.Z` heading.
# CHANGELOG_SECTION prints one version's notes, without the heading or the
# blank lines before them. `\#` is make's way to write a `#`.
CHANGELOG ?= CHANGELOG.md
CHANGELOG_VERSION = $(firstword $(subst -, ,$(VERSION)))
CHANGELOG_SECTION = awk -v h='\#\# $(CHANGELOG_VERSION)' '$$0 == h { f = 1; next } f && /^\#\# / { exit } f && !s && !NF { next } f { s = 1; print }' $(CHANGELOG)

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
# An annotated tag, locally; pushing it starts the release. The release notes
# are this version's section of CHANGELOG.md, written and reviewed like any
# other change, so the tag carries one line and no editor opens. A version
# with no notes in CHANGELOG.md is refused.
tag:
	@test -n "$(VERSION)" || { echo "make tag: set VERSION, e.g. make tag VERSION=v0.1.0" >&2; exit 1; }
	@case "$(VERSION)" in v[0-9]*) ;; *) echo "make tag: VERSION must look like v0.1.0, not $(VERSION)" >&2; exit 1;; esac
	@test -z "$$(git status --porcelain)" || { echo "make tag: the tree is dirty -- commit or stash first" >&2; exit 1; }
	@! git rev-parse -q --verify "refs/tags/$(VERSION)" >/dev/null || { \
		echo "make tag: $(VERSION) already exists -- delete it first, or pick another version" >&2; exit 1; }
	@$(CHANGELOG_SECTION) | grep -q '[^[:space:]]' || { \
		echo "make tag: $(CHANGELOG) has no notes under '## $(CHANGELOG_VERSION)' -- write them first" >&2; exit 1; }
	git tag -a "$(VERSION)" -m "protium $(VERSION)"
	@echo
	@echo "tagged $(VERSION) locally. Not pushed."
	@echo "next: git push origin $(VERSION)"

# ── make package ────────────────────────────────────────────────────────
#
# Test, build and archive into $(DIST), with checksums. No tag check and no
# signature: `release` adds both. Run on its own to try the packaging.
package:
	@test -n "$(VERSION)" || { echo "make package: set VERSION, e.g. make package VERSION=v0.1.0" >&2; exit 1; }
	@case "$(VERSION)" in v[0-9]*) ;; *) echo "make package: VERSION must look like v0.1.0, not $(VERSION)" >&2; exit 1;; esac
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
	zig build $(RELEASE_FLAGS) -Dversion=$(SOURCE_VERSION) -Dtarget=$(ZIG_TARGET_$(HOST)) \
		$(if $(RUNTIME_SHA256),-Druntime_sha256=$(RUNTIME_SHA256)) --prefix $(DIST)/.build-$(HOST)
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

# ── make sums ───────────────────────────────────────────────────────────
#
# SHA256SUMS over every archive in $(DIST). The release workflow runs it after
# adding the runtime and its sources, so the one signature covers all of them.
sums:
	@ls $(DIST)/*.tar.* > /dev/null || { echo "make sums: no archives in $(DIST)" >&2; exit 1; }
	cd $(DIST) && shasum -a 256 *.tar.* > SHA256SUMS
	@cat $(DIST)/SHA256SUMS

# ── make sign ───────────────────────────────────────────────────────────
#
# Sign $(DIST)/SHA256SUMS keylessly, then verify it as a user will. Meant for
# the release workflow: cosign takes the job's OIDC token from the
# environment, so there is nothing to log in to. Anywhere else cosign opens a
# browser, and the check below fails because the identity is not the workflow.
#
# One bundle (signature, certificate and transparency-log proof in one file):
# cosign 3 refuses the separate .sig and .pem outputs.
sign:
	@test -n "$(VERSION)" || { echo "make sign: set VERSION, e.g. make sign VERSION=v0.1.0" >&2; exit 1; }
	@test -f $(DIST)/SHA256SUMS || { echo "make sign: no $(DIST)/SHA256SUMS -- run make package first" >&2; exit 1; }
	cd $(DIST) && cosign sign-blob --yes SHA256SUMS --bundle SHA256SUMS.sigstore.json
	$(MAKE) --no-print-directory verify VERSION=$(VERSION)

# Check the signature against the identity written into the notes, and the
# archives against the checksums it covers, in that order.
verify:
	@test -n "$(VERSION)" || { echo "make verify: set VERSION, e.g. make verify VERSION=v0.1.0" >&2; exit 1; }
	cd $(DIST) && cosign verify-blob SHA256SUMS --bundle SHA256SUMS.sigstore.json \
		--certificate-identity "$(COSIGN_IDENTITY)" --certificate-oidc-issuer "$(COSIGN_ISSUER)"
	cd $(DIST) && shasum -a 256 -c SHA256SUMS

# ── make notes ──────────────────────────────────────────────────────────
#
# The release notes: this version's section of CHANGELOG.md, then the template
# with this release's version and identity filled in. A pre-release such as
# v0.2.0-rc1 uses v0.2.0's section. No tag is needed, so they can be read
# before tagging.
notes:
	@test -n "$(VERSION)" || { echo "make notes: set VERSION, e.g. make notes VERSION=v0.1.0" >&2; exit 1; }
	@$(CHANGELOG_SECTION) | grep -q '[^[:space:]]' || { \
		echo "make notes: $(CHANGELOG) has no notes under '## $(CHANGELOG_VERSION)'" >&2; exit 1; }
	@mkdir -p $(DIST)
	$(CHANGELOG_SECTION) > $(DIST)/notes.md
	sed -e 's|@VERSION@|$(VERSION)|g' \
		-e 's|@COSIGN_IDENTITY@|$(COSIGN_IDENTITY)|g' \
		-e 's|@COSIGN_ISSUER@|$(COSIGN_ISSUER)|g' \
		$(NOTES_TEMPLATE) >> $(DIST)/notes.md
	@! grep -n '@[A-Z_]*@' $(DIST)/notes.md || { echo "make notes: a marker above was not filled in" >&2; exit 1; }

