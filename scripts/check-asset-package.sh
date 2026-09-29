#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
treeish="${ASSET_TREEISH:-HEAD}"
archive="$(mktemp)"
extract_dir="$(mktemp -d)"
trap 'rm -f "$archive"; rm -rf "$extract_dir"' EXIT

git -C "$repo_root" archive --format=tar "$treeish" > "$archive"

unexpected="$(tar -tf "$archive" | grep -Ev '^addons/$|^addons/lazily(/|$)' || true)"
if [[ -n "$unexpected" ]]; then
	echo "ERROR: Asset Library archive contains paths outside addons/lazily/:" >&2
	printf '%s\n' "$unexpected" >&2
	exit 1
fi

required=(
	addons/lazily/LICENSE
	addons/lazily/NOTICE
	addons/lazily/README.md
	addons/lazily/VERSION
	addons/lazily/icon.png
	addons/lazily/lazily.gd
)
archive_paths="$(tar -tf "$archive")"
for path in "${required[@]}"; do
	if ! grep -Fxq "$path" <<< "$archive_paths"; then
		echo "ERROR: Asset Library archive is missing $path" >&2
		exit 1
	fi
done

if tar -xOf "$archive" addons/lazily/lazily.gd | grep -Eq '/home/|/Users/'; then
	echo "ERROR: shipping addon exposes a private workspace path" >&2
	exit 1
fi

tar -xf "$archive" -C "$extract_dir" addons/lazily/icon.png
python3 - "$extract_dir/addons/lazily/icon.png" <<'PY'
from pathlib import Path
import struct
import sys

data = Path(sys.argv[1]).read_bytes()
if data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
    raise SystemExit("ERROR: addon icon is not a valid PNG")
width, height = struct.unpack(">II", data[16:24])
if width != height or width < 128:
    raise SystemExit(f"ERROR: addon icon must be square and at least 128px (got {width}x{height})")
print(f"Asset Library icon OK: {width}x{height}")
PY

file_count="$(tar -tf "$archive" | grep -v '/$' | wc -l)"
echo "Asset Library package OK: ${file_count} files, addons/lazily/ only"
