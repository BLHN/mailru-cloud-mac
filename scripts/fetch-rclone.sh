#!/bin/zsh
# Fetch the pinned official rclone release for macOS (arm64 and amd64) from downloads.rclone.org,
# check both archives against the SHA-256 sums pinned below, and combine them into one universal
# binary. Prints the path of that binary on stdout; everything else goes to stderr.
#
# The pinned sums were copied once from the release's SHA256SUMS file
# (https://downloads.rclone.org/v1.75.2/SHA256SUMS, PGP-signed by the rclone release key, see
# https://rclone.org/release_signing/). The script also re-reads that file when it downloads and
# refuses to continue if it disagrees with the pins.
#
# Cache: $RCLONE_CACHE_DIR (default .build/rclone-cache). Archives are downloaded only when missing
# or broken, so later builds work offline.
set -euo pipefail

VERSION="v1.75.2"
typeset -A PINNED
PINNED[arm64]="610ab7d48615135dfc60b763858b11a426a0d3d1160c1bb76fb0ae6011b02edd"
PINNED[amd64]="574e1f31cf1c464e5fb0325cb66fcbdeaf1efa1802bd9b17f13c256fd74b6561"
BASE="https://downloads.rclone.org/$VERSION"

cd "$(dirname "$0")/.."
CACHE="${RCLONE_CACHE_DIR:-.build/rclone-cache}"
mkdir -p "$CACHE"
CACHE="$(cd "$CACHE" && pwd)"
OUT="$CACHE/rclone-$VERSION-universal"

sha() { shasum -a 256 "$1" | awk '{print $1}'; }

for ARCH in arm64 amd64; do
  ZIP="$CACHE/rclone-$VERSION-osx-$ARCH.zip"
  if [[ ! -f "$ZIP" || "$(sha "$ZIP")" != "${PINNED[$ARCH]}" ]]; then
    SUMS="$CACHE/SHA256SUMS-$VERSION"
    if [[ ! -f "$SUMS" ]]; then
      echo "fetch-rclone: downloading $BASE/SHA256SUMS" >&2
      curl -fsSL --proto '=https' --tlsv1.2 -o "$SUMS.part" "$BASE/SHA256SUMS" && mv "$SUMS.part" "$SUMS"
    fi
    LISTED="$(awk -v f="rclone-$VERSION-osx-$ARCH.zip" '$2 == f {print $1}' "$SUMS")"
    if [[ "$LISTED" != "${PINNED[$ARCH]}" ]]; then
      echo "fetch-rclone: SHA256SUMS lists '$LISTED' for $ARCH, pinned is ${PINNED[$ARCH]}. Stopping." >&2
      exit 1
    fi
    echo "fetch-rclone: downloading $BASE/rclone-$VERSION-osx-$ARCH.zip" >&2
    curl -fsSL --proto '=https' --tlsv1.2 -o "$ZIP.part" "$BASE/rclone-$VERSION-osx-$ARCH.zip"
    if [[ "$(sha "$ZIP.part")" != "${PINNED[$ARCH]}" ]]; then
      echo "fetch-rclone: SHA-256 of the $ARCH archive does not match the pin. Stopping." >&2
      mv "$ZIP.part" "$HOME/.Trash/rclone-$VERSION-osx-$ARCH-bad-$(date +%Y%m%d-%H%M%S).zip"
      exit 1
    fi
    mv "$ZIP.part" "$ZIP"
  fi
done

# The universal binary is rebuilt from the archives checked above on every run (a few seconds),
# so a changed or damaged copy in the cache never reaches a bundle.
WORK="$(mktemp -d "$CACHE/unpack.XXXXXX")"
for ARCH in arm64 amd64; do
  mkdir -p "$WORK/$ARCH"
  unzip -q -j "$CACHE/rclone-$VERSION-osx-$ARCH.zip" "rclone-$VERSION-osx-$ARCH/rclone" -d "$WORK/$ARCH"
done
mkdir -p "$OUT"
lipo -create "$WORK/arm64/rclone" "$WORK/amd64/rclone" -output "$OUT/rclone.part"
xattr -c "$OUT/rclone.part"
chmod 755 "$OUT/rclone.part"
mv -f "$OUT/rclone.part" "$OUT/rclone"
# Scratch folder made by this script a moment ago.
rm -rf "$WORK"

echo "$OUT/rclone"
