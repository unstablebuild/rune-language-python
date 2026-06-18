#!/bin/sh
# Confined pip redirect, shipped as pip / pip3 / pip2 in the package bin so it
# shadows any host pip on PATH (PATH prepends $RUNE_DATADIR/bin; see config.yaml
# gui.env). Rune manages Python through uv: a raw `pip install` into the
# uv-managed venv silently desyncs uv.lock / pyproject.toml and can escape the
# confinement root, so this shim refuses to run and points at the supported
# confined workflows instead. Always exits non-zero so scripts that expect pip
# fail loudly rather than mutating the environment unexpectedly.
prog=$(basename "$0")
cat >&2 <<MSG
$prog is disabled in this Rune-managed Python environment.

Rune manages Python with uv; using $prog directly would bypass the
project's lockfile and the confinement root. Use one of these instead:

  uv pip install <pkg>     add a package to the active environment
  uv add <pkg>             add a dependency to pyproject.toml + uv.lock
  uv sync                  install/refresh the project's locked deps

Or open the Rune shell (via `shell` command) and use the `python` command
to manage your dependencies:

## python

Manage the Python toolchain through uv.

Usage: python <command> [<args>]


### Subcommands

•install [<version>] Install a Python interpreter version.
•list List available and installed Python versions.
•find Find an installed Python interpreter.
•pin <version> Pin the project to a Python version.
•uninstall <version> Uninstall a Python interpreter version.
•init [<path>] Initialize a new uv project.
•add <package>... Add dependencies to the project.
•remove <package>... Remove dependencies from the project.
•sync Sync the environment with the project lockfile.
•lock Update the project lockfile.
•tree Display the project dependency tree.
•build Build the project into distributable archives.
•run <command> [<args>] Run a command in the project environment.
•tool <args> Run and manage tools provided by Python packages.
•pip <args> Manage packages with a pip-compatible interface.
•venv [<path>] Create a virtual environment.
•cache <args> Manage the uv cache.
•self <args> Manage the uv executable.
MSG
exit 1
