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

Releases are published by the [Release workflow](.github/workflows/release.yml).
Pushing a `vX.Y.Z` tag builds the four tarballs (`linux`/`darwin` ×
`amd64`/`arm64`), each on a GitHub runner of its own OS and architecture. Each
tarball is checked with `make test`, then all four are published to the prod
CDN. Nothing is published unless all four build and pass. Tags with any other
shape (`v1.2.3-rc1`, `v1.2`) do not trigger it.

```sh
git tag v1.2.3 && git push origin v1.2.3
```

- **Dry run:** start the workflow manually from the Actions tab. It builds and
  tests all four targets with ad-hoc macOS signing and publishes nothing. The
  tarballs are attached to the run as artifacts.
- **Re-runs:** published versions are immutable, and bluectl refuses to upload
  one twice. Each target publishes in its own job, so if an upload fails, use
  *Re-run failed jobs*.

### OS floors

Release binaries must load on the oldest platforms that docs.rune.build
supports: glibc 2.28 and macOS 13.3. `extension_python` is built without cgo,
so it links no glibc and does not inherit the build host's macOS SDK version.
`tree-sitter.so` is built with `-mmacosx-version-min=13.3`. `make test` fails
if any binary in the tarball needs a newer glibc or macOS, or was built for
another OS or architecture.

### Manual release

Use this when CI is unavailable.

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
   that the debugpy version pins agree. It also checks that every binary
   matches the target OS and architecture and stays within the OS floors.
4. **Publish** using the matching environment, OS, and architecture target:

   ```sh
   make dist-staging-darwin-arm64   # on macOS
   make dist-prod-darwin-amd64      # on macOS
   make dist-staging-linux-arm64    # on Linux
   make dist-prod-linux-amd64       # on Linux
   ```

   All `staging`/`prod` × `darwin`/`linux` × `arm64`/`amd64` combinations
   follow this pattern. Each target cleans, rebuilds, signs and notarizes on
   macOS, runs `make test`, and uploads `python.tar.gz` through the matching
   `upload-<env>-<os>-<arch>` target. That target uploads an existing tarball
   (`TAR=<path>`) without building it. It selects the pinned project and
   platform bucket from `deploy/bluectl/`; do not run `dist.sh` directly.