#!/usr/bin/env bash
# Copy this repo's tracked files to DEST, ready for the Windows build.
#
# The Windows build runs apply_patches.py --windows against a copy of the
# sources rather than the checkout itself, so a build never leaves compiled
# patch binaries or .nimcache behind in the working tree. The copy is
# byte-identical to HEAD: the Windows-only edits (the win32 gates in the custom
# models and Extra settings modules, the Models-only Settings nav, the 8.3
# short-path fallback, apply_patches.py --windows, the patches/windows Makefile
# rule) live in the tree itself, not in a patch layer.
#
# Usage: scripts/windows/prepare-sources.sh DEST

set -euo pipefail

DEST="${1:?usage: prepare-sources.sh DEST}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

mkdir -p "$DEST"
[ -z "$(ls -A "$DEST")" ] || { echo "[prepare-sources] $DEST is not empty" >&2; exit 1; }

# Tracked files only, as they are in the working tree.
( cd "$REPO_DIR" && git ls-files -z | tar --null -T - -cf - ) | tar -xf - -C "$DEST"
echo "[prepare-sources] sources copied to $DEST"
