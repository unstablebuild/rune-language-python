#!/usr/bin/env bash
# Verifies properties of the built release tarball ($TAR). Run after `make`.
#
# Guards:
#   1. No .go source files leak into the tarball. The repo vendors the `rune`
#      Go submodule and builds extension_python from it, so a stray copy of Go
#      sources into pkg/ would ship source into the release. The payload must
#      contain only the compiled extension_python binary, the toolchain
#      binaries, the tree-sitter .so, the .scm queries, and config.yaml.
#   2. The three debugpy version pins agree: the Makefile's DEBUGPY_VERSION,
#      the `uvx --from debugpy==X` pin in config.yaml's debugger.python.command,
#      and the extensions.python.config.debugpy prewarm pin. A mismatch would
#      prewarm one debugpy env and resolve another at first debug (defeating
#      the offline-first prewarm).
set -euo pipefail

TAR="${TAR:-python.tar.gz}"

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

# Guard 2: debugpy pin agreement.
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
