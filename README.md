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

Releases are built and published from a Mac: `make dist-<env>-all` builds,
tests and uploads all four tarballs (`darwin`/`linux` × `arm64`/`amd64`).

1. **Prepare the Mac.** Install Go, `zig`, `wget`, GNU tar (`gtar`) and
   `bluectl`. Signing needs the `Developer ID Application: Unstable Build,
   LLC. (YYZRWD888J)` identity in your keychain, and notarization a
   notarytool profile (`make notary-credentials` sets it up).
2. **Prepare the release.** Fetch tags and submodules
   (`git fetch --tags && git submodule update --init --recursive`) and check
   out the release tag. Authenticate `bluectl` with gcloud Application Default
   Credentials and set `BLUE_PGP_KEY` and `BLUE_PGP_KEYRING` (see
   `bluectl release upload -h`). Set `BLUE_PGP_PASSPHRASE` too, or bluectl
   prompts for it on every upload.
3. **Publish**, to staging first:

   ```sh
   make dist-staging-all
   make dist-prod-all
   ```

`dist-<env>-all` runs `dist-<env>-<os>-<arch>` for each target, one after the
other. Each one first checks that HEAD is a clean checkout of a semver tag
(`check-release-tag.sh`: `v1.2.3` or `v1.2.3-beta.1`, nothing untagged or
dirty), then cleans, builds, signs and notarizes (macOS targets), runs
`make test`, and uploads `python.tar.gz` to the project and bucket pinned in
`deploy/bluectl/<env>/<os>-<arch>`; do not run `dist.sh` directly. Published
versions are immutable, so if a target fails, fix it and run the
`dist-<env>-<os>-<arch>` targets that did not upload, e.g.
`make dist-prod-linux-amd64`.

macOS binaries must be signed with the Developer ID: Rune runs with the
hardened runtime and library validation, so it refuses to load a
`tree-sitter.so` signed by any other team, and an ad-hoc signed one fails with
"different Team IDs". `make test` fails a macOS tarball unless every binary is
signed by `YYZRWD888J` with the hardened runtime. Notarization fails the build
unless Apple reports `status: Accepted`.

`dist-<env>-all` and the macOS `dist-*` targets only run on macOS; Linux targets
also build on Linux. To check a target without publishing it:

```sh
make clean
make notarize python.tar.gz test TARGET_OS=darwin TARGET_ARCH=arm64
```

### OS floors

Release binaries must load on the oldest platforms that docs.rune.build
supports: glibc 2.28 and macOS 13.3. `extension_python` is built without cgo,
so it links no glibc and does not inherit the build host's macOS SDK version.
`tree-sitter.so` is built with `-mmacosx-version-min=13.3` for macOS and with
`zig cc -target <arch>-linux-gnu.2.28` for Linux. `make test` fails if any
binary in the tarball needs a newer glibc or macOS, or was built for another OS
or architecture.
