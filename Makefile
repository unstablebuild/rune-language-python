SRC=tree-sitter-python nvim-treesitter rune
PKG_STAMP=.pkg.stamp
TAR=python.tar.gz
NOTARIZE_ZIP=python-notarize.zip
GTAR=$(if $(filter Darwin,$(UNAME)),gtar,tar)
CODESIGN_IDENTITY=Developer ID Application: Unstable Build, LLC. (YYZRWD888J)
NOTARY_PROFILE=notary-profile
# notarytool credentials: the keychain profile from `make notary-credentials`
# by default. CI overrides this with an App Store Connect API key.
NOTARY_AUTH=--keychain-profile "$(NOTARY_PROFILE)"
UNAME=$(shell uname)

# Oldest supported macOS (docs.rune.build Prerequisites). Without an explicit
# minimum, clang stamps the build host's SDK version into tree-sitter.so, so a
# parser built on a new macOS refuses to load on older ones.
MACOS_MIN_VERSION=13.3

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

# Releases are always built on a machine running the target OS (Linux releases
# on Linux, macOS releases on macOS); only the architecture may be cross
# compiled. TARGET_OS therefore always equals the host OS, while TARGET_ARCH
# may differ to produce the other arch for the same OS.
HOST_OS=$(shell uname | tr '[:upper:]' '[:lower:]')
HOST_ARCH=$(shell uname -m | sed -e 's/^x86_64$$/amd64/' -e 's/^aarch64$$/arm64/')
TARGET_OS=$(HOST_OS)
TARGET_ARCH?=$(HOST_ARCH)

# Cross is non-empty when building for a different arch than the host.
CROSS=$(filter-out $(HOST_ARCH),$(TARGET_ARCH))

# C compiler for the tree-sitter parser. On Linux a cross-arch build needs the
# matching GNU cross toolchain (gcc-*-cross packages); native builds use gcc.
# macOS builds a universal binary in one pass, so CC is unused there.
GNU_TRIPLE_amd64=x86_64-linux-gnu
GNU_TRIPLE_arm64=aarch64-linux-gnu
CC=$(if $(CROSS),$(GNU_TRIPLE_$(TARGET_ARCH))-gcc,gcc)

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
UPLOAD_TARGETS := $(DIST_TARGETS:dist-%=upload-%)

.PHONY: $(DIST_TARGETS) $(UPLOAD_TARGETS) clean sign notarize notary-credentials toolchain test pkg
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
ifeq ($(HOST_OS),darwin)
	cd tree-sitter-python && cc -o parser.so -I./src src/*.c -Os -bundle -arch arm64 -arch x86_64 -mmacosx-version-min=$(MACOS_MIN_VERSION)
else
	cd tree-sitter-python && $(CC) -o parser.so -I./src src/*.c -Os -shared -fPIC
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

ifeq ($(UNAME),Darwin)
sign: $(PKG_STAMP)
	codesign --force --options runtime --sign "$(CODESIGN_IDENTITY)" pkg/bin/uv
	codesign --force --options runtime --sign "$(CODESIGN_IDENTITY)" pkg/bin/uvx
	codesign --force --options runtime --sign "$(CODESIGN_IDENTITY)" pkg/bin/ruff
	codesign --force --options runtime --sign "$(CODESIGN_IDENTITY)" pkg/bin/ty
	codesign --force --options runtime --sign "$(CODESIGN_IDENTITY)" pkg/bin/extension_python
	codesign --force --options runtime --sign "$(CODESIGN_IDENTITY)" pkg/lib/tree-sitter.so

$(NOTARIZE_ZIP): sign
	zip $(NOTARIZE_ZIP) pkg/bin/uv pkg/bin/uvx pkg/bin/ruff pkg/bin/ty pkg/bin/extension_python pkg/lib/tree-sitter.so

notarize: $(NOTARIZE_ZIP)
	@# notarytool can exit 0 for a rejected submission, so require Accepted.
	@out=$$(xcrun notarytool submit $(NOTARIZE_ZIP) $(NOTARY_AUTH) --wait) || { echo "$$out"; exit 1; }; \
	 echo "$$out"; \
	 echo "$$out" | grep -Eq '^[[:space:]]*status: Accepted' || { echo "error: notarization was not accepted" >&2; exit 1; }
else
sign: $(PKG_STAMP)
	@echo "Skipping codesign (not on macOS)"

notarize: sign
	@echo "Skipping notarization (not on macOS)"
endif

$(TAR): $(PKG_STAMP) sign
	cd pkg && $(GTAR) --no-xattrs --no-acls -czvf ../$(TAR) .

# Verify release-tarball properties (no .go source leaks, binaries built for the
# target os/arch and within the documented OS floors, etc).
test: $(TAR)
	TAR=$(TAR) TARGET_OS=$(TARGET_OS) TARGET_ARCH=$(TARGET_ARCH) ./scripts/test.sh

# dist-<env>-<os>-<arch>: build (cross compiling the architecture when it
# differs from the host), sign/notarize, test, and upload via
# upload-<env>-<os>-<arch>. Pattern stem is <env>-<os>-<arch>, e.g.
# "prod-darwin-arm64".
#
# The target OS must match the host OS: Linux releases are built on Linux and
# macOS releases on macOS. Only the architecture may be cross compiled. The
# build is driven through a recursive make so TARGET_ARCH is set before the
# $(TAR) prerequisite chain is evaluated.
$(DIST_TARGETS): dist-%:
	@os=$$(echo $*  | cut -d- -f2); \
	 arch=$$(echo $* | cut -d- -f3); \
	 set -e; \
	 if [ "$$os" != "$(HOST_OS)" ]; then \
	   echo "error: $@ targets OS '$$os' but host OS is '$(HOST_OS)'; build $$os releases on a $$os machine" >&2; \
	   exit 1; \
	 fi; \
	 $(MAKE) clean; \
	 $(MAKE) notarize $(TAR) test TARGET_ARCH=$$arch; \
	 $(MAKE) upload-$*

# upload-<env>-<os>-<arch>: upload an already built $(TAR) for <os>-<arch> to
# the bluectl project-id and bucket pinned by
# deploy/bluectl/<env>/<os>-<arch>/config. It builds nothing, so it runs on any
# host: CI builds each tarball on its own runner and uploads it from Linux,
# passing TAR=<path> to the downloaded artifact.
$(UPLOAD_TARGETS): upload-%:
	@env=$$(echo $* | cut -d- -f1); \
	 os=$$(echo $*  | cut -d- -f2); \
	 arch=$$(echo $* | cut -d- -f3); \
	 BLUECTL_CONFIG_DIR=$(BLUECTL_CONFIG_ROOT)/$$env/$$os-$$arch \
	 BLUE_TARGET_OS=$$os BLUE_TARGET_ARCH=$$arch BLUE_RELEASE_TAR=$(TAR) ./dist.sh

notary-credentials:
	xcrun notarytool store-credentials "$(NOTARY_PROFILE)" --team-id "YYZRWD888J"

clean:
	rm -rf $(TAR)
	rm -rf $(NOTARIZE_ZIP)
	rm -rf $(PKG_STAMP)
	rm -rf pkg/
