#!/bin/bash
# Compiles launcher/main.c to the given output path.
#
# Some Macs have Command Line Tools whose newest SDK doesn't match the linker
# (e.g. "ld: tapi error: malformed file ... unknown architecture"). If the
# default build fails, retry against each installed macOS SDK, newest first.
#
# Usage: build_launcher.sh <output>    (exit 0 on success; last error on stderr)
set -uo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)/launcher/main.c"
OUT="$1"
CLANG="${CLANG:-clang}"
TMP="$(mktemp -t koreader-launcher)"
ERR="$(mktemp -t koreader-launcher-err)"
trap 'rm -f "$TMP" "$ERR"' EXIT

try_build() {
  "$CLANG" -O2 "$@" -o "$TMP" "$SRC" 2>"$ERR"
}

# Installed SDKs, newest version first (e.g. MacOSX27.0, MacOSX26.5, MacOSX26).
sdks() {
  local dir sdk name
  for dir in /Library/Developer/CommandLineTools/SDKs \
             "$(xcode-select -p 2>/dev/null)/Platforms/MacOSX.platform/Developer/SDKs"; do
    for sdk in "$dir"/MacOSX[0-9]*.sdk; do
      [[ -d "$sdk" ]] || continue
      name="$(basename "$sdk" .sdk)"
      printf '%s\t%s\n' "${name#MacOSX}" "$sdk"
    done
  done | sort -t $'\t' -k1,1 -V -r | cut -f2
}

if try_build; then
  mv "$TMP" "$OUT"
  exit 0
fi

while IFS= read -r sdk; do
  if try_build -isysroot "$sdk"; then
    echo "Built against $(basename "$sdk") (the default SDK didn't work)"
    mv "$TMP" "$OUT"
    exit 0
  fi
done < <(sdks)

cat "$ERR" >&2
exit 1
