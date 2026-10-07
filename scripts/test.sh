#!/usr/bin/env bash
# Verifies properties of the built release tarball ($TAR). Run after `make`.
#
# Guards:
#   1. No .go source files leak into the tarball, or into the notarization zip
#      ($NOTARIZE_ZIP) when one was built. The repo vendors the `rune` Go
#      submodule and builds extension_python from it, so a stray copy of Go
#      sources into pkg/ would ship source into the release. The payload must
#      contain only the compiled extension_python binary, the toolchain
#      binaries, the tree-sitter .so, the .scm queries, and config.yaml.
#   2. The tarball holds nothing beyond that enumerated payload, so a stray
#      file that reaches pkg/ fails the release rather than ships.
#   3. The three debugpy version pins agree: the Makefile's DEBUGPY_VERSION,
#      the `uvx --from debugpy==X` pin in config.yaml's debugger.python.command,
#      and the extensions.python.config.debugpy prewarm pin. A mismatch would
#      prewarm one debugpy env and resolve another at first debug (defeating
#      the offline-first prewarm).
#   4. Every native binary (ELF or Mach-O) is built for $TARGET_OS/$TARGET_ARCH
#      and loads on the oldest OS that docs.rune.build lists as supported:
#      glibc 2.28 on Linux, macOS 13.3. Toolchains default to the build host's
#      versions, so a release built on a newer host silently raises the floor.
#      Needs file, objdump (GNU binutils, or the LLVM one Xcode ships, so a
#      Linux tarball can be checked on macOS) and, for macOS, otool.
#   5. macOS targets: every slice of every Mach-O carries a valid signature
#      from $TEAM_ID with the hardened runtime. Rune runs with library
#      validation, so it refuses to dlopen a tree-sitter.so signed by anyone
#      else (an ad-hoc signature fails with "different Team IDs"), and
#      notarization requires the hardened runtime.
set -euo pipefail

TAR="${TAR:-python.tar.gz}"
: "${TARGET_OS:?TARGET_OS is not set; run 'make test'}"
: "${TARGET_ARCH:?TARGET_ARCH is not set; run 'make test'}"

if [ ! -f "$TAR" ]; then
	echo "error: $TAR not found; run 'make' first" >&2
	exit 1
fi

# List archive members. Matches the build's gtar invocation (entries are
# relative to pkg/, e.g. ./bin/extension_python).
members="$(tar -tzf "$TAR")"

go_files="$(printf '%s\n' "$members" | grep -E '\.go$' || true)"
if [ -n "$go_files" ]; then
	echo "error: $TAR contains .go source files:" >&2
	printf '%s\n' "$go_files" >&2
	exit 1
fi

echo "ok: no .go files in $TAR"

if [ -n "${NOTARIZE_ZIP:-}" ] && [ -f "$NOTARIZE_ZIP" ]; then
	go_files="$(unzip -Z1 "$NOTARIZE_ZIP" | grep -E '\.go$' || true)"
	if [ -n "$go_files" ]; then
		echo "error: $NOTARIZE_ZIP contains .go source files:" >&2
		printf '%s\n' "$go_files" >&2
		exit 1
	fi
	echo "ok: no .go files in $NOTARIZE_ZIP"
fi

# Guard 2: only the expected members. Keep in sync with the $(PKG_STAMP) and
# toolchain recipes in the Makefile.
expected='./
./bin/
./bin/extension_python
./bin/pip
./bin/pip2
./bin/pip3
./bin/ruff
./bin/ty
./bin/uv
./bin/uvx
./config.yaml
./lib/
./lib/folds.scm
./lib/highlights.scm
./lib/indents.scm
./lib/locals.scm
./lib/tags.scm
./lib/tree-sitter.so'
unexpected="$(comm -13 <(printf '%s\n' "$expected" | sort) <(printf '%s\n' "$members" | sort))"
if [ -n "$unexpected" ]; then
	echo "error: $TAR contains files outside the expected payload:" >&2
	printf '%s\n' "$unexpected" >&2
	exit 1
fi

echo "ok: $TAR contains only the expected payload"

# Guard 3: debugpy pin agreement.
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
makefile_pin="$(sed -n 's/^DEBUGPY_VERSION=//p' "$repo_root/Makefile")"
adapter_pin="$(sed -n 's/.*uvx --from debugpy==\([0-9][0-9.]*\) .*/\1/p' "$repo_root/config.yaml")"
prewarm_pin="$(sed -n 's/^ *debugpy: *"\([0-9][0-9.]*\)".*/\1/p' "$repo_root/config.yaml")"

if [ -z "$makefile_pin" ] || [ -z "$adapter_pin" ] || [ -z "$prewarm_pin" ]; then
	echo "error: could not extract all debugpy pins" >&2
	echo "  Makefile DEBUGPY_VERSION:                  '$makefile_pin'" >&2
	echo "  config.yaml debugger.python.command:       '$adapter_pin'" >&2
	echo "  config.yaml extensions.python.config.debugpy: '$prewarm_pin'" >&2
	exit 1
fi

if [ "$makefile_pin" != "$adapter_pin" ] || [ "$makefile_pin" != "$prewarm_pin" ]; then
	echo "error: debugpy version pins disagree:" >&2
	echo "  Makefile DEBUGPY_VERSION:                  $makefile_pin" >&2
	echo "  config.yaml debugger.python.command:       $adapter_pin" >&2
	echo "  config.yaml extensions.python.config.debugpy: $prewarm_pin" >&2
	exit 1
fi

echo "ok: debugpy pins agree ($makefile_pin)"

# Guard 4: target os/arch and OS version floors.
GLIBC_FLOOR=2.28
MACOS_FLOOR=13.3

# version_gt A B: true when dotted version A is newer than B.
version_gt() {
	[ "$1" != "$2" ] &&
		[ "$(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)" = "$1" ]
}

case "$TARGET_OS-$TARGET_ARCH" in
linux-amd64) want_format="ELF" want_arch="x86-64" ;;
linux-arm64) want_format="ELF" want_arch="aarch64" ;;
darwin-amd64) want_format="Mach-O" want_arch="x86_64" ;;
darwin-arm64) want_format="Mach-O" want_arch="arm64" ;;
*)
	echo "error: unsupported target $TARGET_OS-$TARGET_ARCH" >&2
	exit 1
	;;
esac
if [ "$TARGET_OS" = darwin ]; then
	: "${TEAM_ID:?TEAM_ID is not set; run 'make test'}"
fi

extracted="$(mktemp -d)"
trap 'rm -rf "$extracted"' EXIT
tar -xzf "$TAR" -C "$extracted"

binaries=0
failed=0
while IFS= read -r -d '' f; do
	desc="$(file -b "$f")"
	case "$desc" in
	ELF* | Mach-O*) ;;
	*) continue ;;
	esac
	binaries=$((binaries + 1))
	name="${f#"$extracted"/}"
	case "$desc" in
	"$want_format"*"$want_arch"*) ;;
	*)
		echo "error: $name is not a $TARGET_OS-$TARGET_ARCH binary: $desc" >&2
		failed=1
		continue
		;;
	esac
	if [ "$want_format" = ELF ]; then
		# Version requirements on glibc; a static binary has none.
		need="$(objdump -p "$f" |
			sed -n 's/.*[[:space:]]GLIBC_\([0-9][0-9.]*\)$/\1/p' |
			sort -t. -k1,1n -k2,2n -k3,3n | tail -1)"
		if [ -n "$need" ] && version_gt "$need" "$GLIBC_FLOOR"; then
			echo "error: $name requires GLIBC_$need; the floor is $GLIBC_FLOOR" >&2
			failed=1
		fi
	else
		# Minimum macOS of every architecture slice, from LC_BUILD_VERSION
		# (minos) or the older LC_VERSION_MIN_MACOSX (version).
		mins="$(otool -arch all -l "$f" | awk '
			$1 == "cmd" { build = ($2 == "LC_BUILD_VERSION"); legacy = ($2 == "LC_VERSION_MIN_MACOSX"); next }
			build && $1 == "minos" { print $2 }
			legacy && $1 == "version" { print $2; legacy = 0 }')"
		if [ -z "$mins" ]; then
			echo "error: $name has no minimum macOS version" >&2
			failed=1
		fi
		for min in $mins; do
			if version_gt "$min" "$MACOS_FLOOR"; then
				echo "error: $name requires macOS $min; the floor is $MACOS_FLOOR" >&2
				failed=1
			fi
		done
		# Guard 5: signed by $TEAM_ID with the hardened runtime, per slice.
		for slice in $(lipo -archs "$f"); do
			if ! codesign --verify --strict --arch "$slice" "$f" 2>/dev/null; then
				echo "error: $name ($slice) has no valid code signature" >&2
				failed=1
				continue
			fi
			info="$(codesign -dv --arch "$slice" "$f" 2>&1)"
			team="$(printf '%s\n' "$info" | sed -n 's/^TeamIdentifier=//p')"
			if [ "$team" != "$TEAM_ID" ]; then
				echo "error: $name ($slice) is signed by team '$team', not $TEAM_ID; Rune will refuse to load it" >&2
				failed=1
			fi
			if ! printf '%s\n' "$info" | grep -Eq 'flags=0x[0-9a-f]+\([^)]*runtime'; then
				echo "error: $name ($slice) is not signed with the hardened runtime" >&2
				failed=1
			fi
		done
	fi
done < <(find "$extracted" -type f -print0)

if [ "$binaries" -eq 0 ]; then
	echo "error: $TAR contains no native binaries" >&2
	exit 1
fi
if [ "$failed" -ne 0 ]; then
	exit 1
fi

echo "ok: $binaries binaries are $TARGET_OS-$TARGET_ARCH and within the OS floors (glibc $GLIBC_FLOOR, macOS $MACOS_FLOOR)"
if [ "$TARGET_OS" = darwin ]; then
	echo "ok: $binaries binaries are signed by $TEAM_ID with the hardened runtime"
fi
