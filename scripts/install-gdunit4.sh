#!/usr/bin/env bash
# Vendor gdUnit4 into addons/ for LOCAL runs.
#
# gdUnit4 is a test dependency, not a shipping one: it lands in `addons/gdUnit4/`
# next to `addons/lazily/` because that is where Godot looks, and it is gitignored
# so it never reaches a consumer who installs this addon. CI installs it the same
# way rather than through gdUnit4-action, so a local failure and a CI failure are
# the same failure.
#
#   scripts/install-gdunit4.sh          # install the pinned version if absent
#   scripts/install-gdunit4.sh --force  # reinstall over an existing copy
set -euo pipefail

# Pinned. An unpinned test framework means a green suite can turn red without a
# commit, and then the first question is always "did the framework move?".
#
# v5.1.1, NOT the newest release. gdUnit4 v6.x does not compile on the declared
# Godot floor (4.4): on 4.4.1 it dies with "Could not resolve class
# GdUnitCSIMessageWriter" and then HANGS instead of exiting, so CI burns its job
# limit rather than failing. Upstream's compatibility table row listing
# v4.3/v4.4/v4.4.1 covers the v5.x line specifically — reading it as "gdUnit4
# supports 4.4" and then pinning v6 is the exact mistake this comment exists to
# stop someone repeating. Verified: v5.1.1 passes on 4.4.1 (the CI floor) and on
# 4.7.1 (a current engine), so bumping the floor is what should unlock v6, not a
# version bump here on its own.
GDUNIT4_VERSION="${GDUNIT4_VERSION:-v5.1.1}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$HERE/addons/gdUnit4"

if [ -d "$DEST" ] && [ "${1:-}" != "--force" ]; then
  echo "gdUnit4 already present at addons/gdUnit4 (use --force to reinstall)"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

URL="https://github.com/godot-gdunit-labs/gdUnit4/archive/refs/tags/${GDUNIT4_VERSION}.tar.gz"
echo "Fetching gdUnit4 ${GDUNIT4_VERSION}"
curl -fsSL "$URL" -o "$TMP/gdunit4.tar.gz"
tar -xzf "$TMP/gdunit4.tar.gz" -C "$TMP"

SRC="$(find "$TMP" -maxdepth 3 -type d -path '*/addons/gdUnit4' -print -quit)"
if [ -z "$SRC" ]; then
  echo "ERROR: addons/gdUnit4 not found inside ${GDUNIT4_VERSION} tarball." >&2
  echo "       The upstream layout moved; update this script rather than" >&2
  echo "       loosening the search, or the suite will run against nothing." >&2
  exit 1
fi

rm -rf "$DEST"
mkdir -p "$(dirname "$DEST")"
cp -R "$SRC" "$DEST"
echo "Installed gdUnit4 ${GDUNIT4_VERSION} -> addons/gdUnit4"
