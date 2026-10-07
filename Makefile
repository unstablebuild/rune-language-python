SRC=tree-sitter-python nvim-treesitter rune
PKG_STAMP=.pkg.stamp
TAR=python.tar.gz
GTAR=$(if $(filter Darwin,$(UNAME)),gtar,tar)
UNAME=$(shell uname)
# Rune runs with the hardened runtime and library validation, so macOS only
# lets it dlopen a tree-sitter.so signed by Rune's own team; an ad-hoc signed
# one fails with "different Team IDs". scripts/macos-signing.sh signs the
# macOS packages, and scripts/test.sh runs its check. Packages are not
# notarized: Rune installs them without the quarantine attribute, so
# Gatekeeper never assesses them.
TEAM_ID=YYZRWD888J
CODESIGN_IDENTITY=Developer ID Application: Unstable Build, LLC. ($(TEAM_ID))
MACOS_SIGNING=TEAM_ID=$(TEAM_ID) CODESIGN_IDENTITY="$(CODESIGN_IDENTITY)" \
	TARGET_ARCH=$(TARGET_ARCH) ./scripts/macos-signing.sh

# Oldest supported macOS (docs.rune.build Prerequisites). Without an explicit
# minimum, clang stamps the build host's SDK version into tree-sitter.so, so a
# parser built on a new macOS refuses to load on older ones.
MACOS_MIN_VERSION=13.3

# Oldest supported glibc (docs.rune.build Prerequisites). zig cc links the
# Linux tree-sitter.so against it, whatever glibc the build host has.
GLIBC_MIN_VERSION=2.28
ZIG=zig

# Pinned Astral toolchain versions (downloaded per target os/arch). No CPython
# is bundled; `uv python install` provisions the interpreter at first run,
# confined to $RUNE_DATADIR/python via config.yaml gui.env. Interpreter links
# land in $RUNE_DATADIR/python/uvbin (UV_PYTHON_BIN_DIR), which is kept off
# PATH so the managed interpreter never shadows the user's; uv tool bins land
# in $RUNE_DATADIR/python/toolbin (UV_TOOL_BIN_DIR). $RUNE_DATADIR/python/bin
# holds Rune's venv-aware python/python3 shims, written by extension_python at
# bootstrap, which stay first on PATH and defer to the venv, then the user's
# interpreter, then uvbin.
UV_VERSION=0.11.22
RUFF_VERSION=0.15.18
TY_VERSION=0.0.51
# debugpy is NOT bundled: it ships platform+CPython-ABI-specific wheels (not
# py3-none-any), so a build-time wheel could pin a cpXYZ ABI tag that mismatches
# the uv-managed interpreter installed at first run. The DAP command in
# config.yaml resolves it at first debug via `uvx --from debugpy==$(DEBUGPY_VERSION)`,
# isolated in its own uv env and confined by the UV_* gui.env. Keep this in sync
# with the pins in config.yaml's debugger.python.command and
# extensions.python.config.debugpy (scripts/test.sh enforces agreement).
DEBUGPY_VERSION=1.8.17

# macOS releases are built on macOS, which builds their tree-sitter.so with
# clang, then signs them. Linux releases build on any host:
# extension_python is built with cgo off, the Astral tools are downloaded per
# target, and tree-sitter.so is cross compiled with zig cc.
HOST_OS=$(shell uname | tr '[:upper:]' '[:lower:]')
HOST_ARCH=$(shell uname -m | sed -e 's/^x86_64$$/amd64/' -e 's/^aarch64$$/arm64/')
TARGET_OS?=$(HOST_OS)
TARGET_ARCH?=$(HOST_ARCH)

# Astral release asset arch/os naming (rust target triples).
RUST_ARCH_amd64=x86_64
RUST_ARCH_arm64=aarch64
RUST_ARCH=$(RUST_ARCH_$(TARGET_ARCH))
RUST_OS_darwin=apple-darwin
RUST_OS_linux=unknown-linux-gnu
RUST_OS=$(RUST_OS_$(TARGET_OS))
RUST_TRIPLE=$(RUST_ARCH)-$(RUST_OS)

BLUECTL_CONFIG_ROOT := $(abspath deploy/bluectl)

DIST_TARGETS := \
	dist-prod-darwin-arm64 dist-prod-darwin-amd64 \
	dist-prod-linux-arm64  dist-prod-linux-amd64  \
	dist-staging-darwin-arm64 dist-staging-darwin-amd64 \
	dist-staging-linux-arm64  dist-staging-linux-amd64
DIST_ALL_TARGETS := dist-prod-all dist-staging-all

.PHONY: $(DIST_TARGETS) $(DIST_ALL_TARGETS) check-release-tag check-macos clean sign toolchain test pkg
default: $(TAR)

pkg: $(PKG_STAMP)

# Stage the Astral toolchain into pkg/bin (uv/uvx/ruff/ty) for the target
# os/arch. debugpy is not staged (resolved at runtime via uvx; see above).
toolchain:
	@mkdir -p pkg/bin pkg/lib
	# uv (tarball: uv-<triple>.tar.gz, contains uv + uvx)
	wget -O uv.tar.gz https://github.com/astral-sh/uv/releases/download/$(UV_VERSION)/uv-$(RUST_TRIPLE).tar.gz
	tar -xzf uv.tar.gz --strip-components=1 -C pkg/bin uv-$(RUST_TRIPLE)/uv uv-$(RUST_TRIPLE)/uvx
	rm -f uv.tar.gz
	# ruff (tarball: ruff-<triple>.tar.gz)
	wget -O ruff.tar.gz https://github.com/astral-sh/ruff/releases/download/$(RUFF_VERSION)/ruff-$(RUST_TRIPLE).tar.gz
	tar -xzf ruff.tar.gz --strip-components=1 -C pkg/bin ruff-$(RUST_TRIPLE)/ruff
	rm -f ruff.tar.gz
	# ty (tarball: ty-<triple>.tar.gz)
	wget -O ty.tar.gz https://github.com/astral-sh/ty/releases/download/$(TY_VERSION)/ty-$(RUST_TRIPLE).tar.gz
	tar -xzf ty.tar.gz --strip-components=1 -C pkg/bin ty-$(RUST_TRIPLE)/ty
	rm -f ty.tar.gz
	# debugpy is intentionally NOT staged here; it is resolved at first debug
	# via `uvx --from debugpy==$(DEBUGPY_VERSION)` (see config.yaml), which picks
	# the wheel matching the uv-managed interpreter's CPython ABI.
	# pip/pip3/pip2 redirect shims: shadow any host pip on PATH and refuse to
	# run, pointing the user at `uv pip`/`uv add`/`uv sync` (see scripts/pip-shim.sh).
	install -m 0755 scripts/pip-shim.sh pkg/bin/pip
	install -m 0755 scripts/pip-shim.sh pkg/bin/pip3
	install -m 0755 scripts/pip-shim.sh pkg/bin/pip2

$(PKG_STAMP): $(SRC) config.yaml scripts/pip-shim.sh toolchain
	@mkdir -p pkg/bin pkg/lib
ifeq ($(TARGET_OS),darwin)
	cd tree-sitter-python && cc -o parser.so -I./src src/*.c -Os -bundle -arch arm64 -arch x86_64 -mmacosx-version-min=$(MACOS_MIN_VERSION)
else
	cd tree-sitter-python && $(ZIG) cc -target $(RUST_ARCH)-linux-gnu.$(GLIBC_MIN_VERSION) -o parser.so -I./src src/*.c -Os -shared -fPIC
endif
	cp tree-sitter-python/parser.so pkg/lib/tree-sitter.so
	cp tree-sitter-python/queries/highlights.scm tree-sitter-python/queries/tags.scm pkg/lib
	cp nvim-treesitter/queries/python/indents.scm pkg/lib
	cp nvim-treesitter/queries/python/locals.scm pkg/lib
	cp nvim-treesitter/queries/python/folds.scm pkg/lib
	# cgo stays off on every target: a cgo build links the build host's glibc
	# (above the documented 2.28 floor on current distros) and on macOS stamps
	# the host SDK as the minimum OS. The extension reaches Rune over a unix
	# socket and resolves no hostnames; the one visible difference is that the
	# pure-Go os/user resolves the current user from $$USER/$$HOME or
	# /etc/passwd rather than NSS.
	cd rune && CGO_ENABLED=0 GOOS=$(TARGET_OS) GOARCH=$(TARGET_ARCH) go build -o $(PWD)/pkg/bin/extension_python ./cmd/extension_python
	cp config.yaml pkg
	@touch $(PKG_STAMP)

ifeq ($(TARGET_OS),darwin)
# Every Mach-O file in pkg/, found by scanning, so a new binary is signed too.
sign: $(PKG_STAMP)
	$(MACOS_SIGNING) sign pkg
else
sign: $(PKG_STAMP)
	@echo "Skipping codesign (not a macOS target)"
endif

$(TAR): $(PKG_STAMP) sign
	cd pkg && $(GTAR) --no-xattrs --no-acls -czvf ../$(TAR) .

# Verify release-tarball properties (no .go source leaks, binaries built for the
# target os/arch and within the documented OS floors, macOS packages loadable
# by Rune.app, etc).
test: $(TAR)
	TAR=$(TAR) TEAM_ID=$(TEAM_ID) CODESIGN_IDENTITY="$(CODESIGN_IDENTITY)" \
	TARGET_OS=$(TARGET_OS) TARGET_ARCH=$(TARGET_ARCH) ./scripts/test.sh

# check-release-tag aborts before any build runs when HEAD does not carry a
# publishable release tag (clean, canonical semver, actually tagged).
check-release-tag:
	@./check-release-tag.sh

# check-macos fails before any build work unless this host can sign: macOS and
# the Developer ID identity.
check-macos:
	@$(MACOS_SIGNING) preflight

# dist-<env>-<os>-<arch>: build, sign (macOS targets), test, and upload to the
# bluectl project-id and bucket pinned by
# deploy/bluectl/<env>/<os>-<arch>/config. Pattern stem is <env>-<os>-<arch>,
# e.g. "prod-darwin-arm64". The build is driven through a recursive make so
# TARGET_OS and TARGET_ARCH are set before the $(TAR) prerequisite chain is
# evaluated.
$(filter %-darwin-arm64 %-darwin-amd64,$(DIST_TARGETS)) $(DIST_ALL_TARGETS): check-macos
$(DIST_TARGETS): dist-%: check-release-tag
	@env=$$(echo $* | cut -d- -f1); \
	 os=$$(echo $*  | cut -d- -f2); \
	 arch=$$(echo $* | cut -d- -f3); \
	 set -e; \
	 $(MAKE) clean; \
	 $(MAKE) test TARGET_OS=$$os TARGET_ARCH=$$arch; \
	 BLUECTL_CONFIG_DIR=$(BLUECTL_CONFIG_ROOT)/$$env/$$os-$$arch \
	 BLUE_TARGET_OS=$$os BLUE_TARGET_ARCH=$$arch ./dist.sh

# dist-<env>-all: dist-<env>-<os>-<arch> for all four targets, one after the
# other since they share pkg/ and $(TAR). It only runs on macOS, which the
# darwin targets need, so a Linux host fails before uploading anything.
# Published versions are immutable, so if a target fails, fix it and run the
# targets that did not upload individually.
$(DIST_ALL_TARGETS): dist-%-all: check-release-tag
	@set -e; for target in darwin-arm64 darwin-amd64 linux-arm64 linux-amd64; do \
	   $(MAKE) dist-$*-$$target; \
	 done

clean:
	rm -rf $(TAR)
	rm -rf $(PKG_STAMP)
	rm -rf pkg/
