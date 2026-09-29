# Python language package

To install Python support in Rune, run this command in the Rune console:

```text
pkg install python
```

This package ships `uv`, `uvx`, `ruff`, `ty`, the Python extension, and the
tree-sitter grammar. It does not bundle CPython: `uv` installs a managed
interpreter on first use. The release instructions below are for Rune
maintainers.

## Release runbook

1. **Prepare the build host.** Build macOS (`darwin`) artifacts on macOS and
   Linux artifacts on Linux; the Makefile supports cross-building the other
   architecture on the same OS. Install Go, a C compiler, `wget`, `bluectl`,
   and tar (GNU `gtar` on macOS). Linux cross-architecture builds need the
   target GNU compiler (`aarch64-linux-gnu-gcc` or `x86_64-linux-gnu-gcc`).
   macOS releases need the configured Developer ID signing identity and a
   notarytool profile (`make notary-credentials` to set it up).
2. **Prepare the release.** Fetch tags and submodules
   (`git fetch --tags && git submodule update --init --recursive`), then check
   out the intended release tag. Authenticate `bluectl` via gcloud Application
   Default Credentials and set `BLUE_PGP_KEY` and `BLUE_PGP_KEYRING` (see
   `bluectl release upload -h`).
3. **Build and check each artifact before publishing** on its target OS,
   substituting `arm64` or `amd64`:

   ```sh
   make clean
   make notarize python.tar.gz TARGET_ARCH=arm64
   make test TARGET_ARCH=arm64
   ```

   `make test` checks that no `.go` source files leak into the tarball and
   that the debugpy version pins agree.
4. **Publish** using the matching environment, OS, and architecture target:

   ```sh
   make dist-staging-darwin-arm64   # on macOS
   make dist-prod-darwin-amd64      # on macOS
   make dist-staging-linux-arm64    # on Linux
   make dist-prod-linux-amd64       # on Linux
   ```

   All `staging`/`prod` × `darwin`/`linux` × `arm64`/`amd64` combinations
   follow this pattern. Each target cleans, rebuilds, signs/notarizes on
   macOS, and uploads `python.tar.gz` via `dist.sh`; it does **not** run
   `make test`. The target selects the pinned project and platform bucket
   from `deploy/bluectl/`; do not run `dist.sh` directly.