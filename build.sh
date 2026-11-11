#!/bin/zsh
# Build CloudMail with SwiftPM and wrap it into dist/<name>.app with rclone inside.
# The app's name is CFBundleName in Packaging/Info.plist, the only place it is written.
# Usage: ./build.sh            -> universal (arm64 + x86_64) build + dist/<name>.app
#        ./build.sh --run      -> same, then open the app
#        ./build.sh --install  -> same, then copy into /Applications/<name>.app and relaunch from there
#        ./build.sh --release  -> same as the plain build, plus dist/<DIST_NAME>-<version>.zip and .dmg
#                                 and dist/SHA256SUMS for both (the app inside keeps its own name)
#        ./build.sh --dev      -> build for this Mac only with CLOUDMAIL_DEV + dist/<name> Dev.app
#                                 (bundle id ru.blhn.cloudmail.dev, no Finder services, no .mailcloud
#                                 type; own queue, log and Keychain item, see AppPaths.swift). Leaves
#                                 dist/<name>.app alone. Run it in the background:
#                                 open -n -g "dist/<name> Dev.app" --args --dev-download <cloud> --dev-to <folder>
#
# Every bundle gets the pinned official rclone (scripts/fetch-rclone.sh, SHA-256 checked) in
# Contents/Helpers/rclone and its licence in Contents/Resources.
#
# Environment:
#   SIGN_IDENTITY     codesign identity, e.g. "BLHN Code Signing". Default "-" (ad-hoc).
#   ARCHS             architectures of the plain/release build. Default "arm64 x86_64".
#   DIST_NAME         ASCII base name of the release archives (GitHub mangles non-ASCII asset
#                     names). Default "Oblachko".
#   RCLONE_CACHE_DIR  where the rclone archives are kept. Default .build/rclone-cache.
set -euo pipefail
cd "$(dirname "$0")"
MODE="${1:-}"
case "$MODE" in ""|--run|--install|--release|--dev) ;; *) echo "Unknown option: $MODE" >&2; exit 2 ;; esac
# Release archives get an ASCII name: GitHub mangles non-ASCII asset names.
DIST_NAME="${DIST_NAME:-Oblachko}"
if [[ ! "$DIST_NAME" =~ '^[A-Za-z0-9._-]+$' ]]; then
  echo "DIST_NAME must be ASCII letters, digits, '.', '_' or '-': $DIST_NAME" >&2; exit 2
fi

NAME="$(/usr/libexec/PlistBuddy -c "Print :CFBundleName" Packaging/Info.plist)"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Packaging/Info.plist)"
MIN_OS="$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" Packaging/Info.plist)"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

if [[ "$SIGN_IDENTITY" != "-" ]] && ! security find-identity -v -p codesigning | grep -qF "\"$SIGN_IDENTITY\""; then
  echo "Signing identity \"$SIGN_IDENTITY\" is not in the keychain (security find-identity -v -p codesigning)." >&2
  echo "Unset SIGN_IDENTITY for an ad-hoc signature." >&2
  exit 1
fi

RCLONE="$(scripts/fetch-rclone.sh)"

# Quiet SwiftPM output: blank lines dropped, the last lines kept (warnings and errors show there).
swift_build() { swift build -c release "$@" 2>&1 | grep -vE "^\s*$" | tail -20; }

# codesign, quiet unless it fails.
sign() { local out; out="$(codesign --force --timestamp=none --sign "$SIGN_IDENTITY" "${@:2}" "$1" 2>&1)" || { echo "$out" >&2; return 1; }; }

# Lay out <app>: binary, Info.plist (already in place), icons, rclone, licences; then sign it.
finish_bundle() {
  local app="$1" bin="$2"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Licenses" "$app/Contents/Helpers"
  cp "$bin" "$app/Contents/MacOS/CloudMail"
  cp "$RCLONE" "$app/Contents/Helpers/rclone"
  chmod 755 "$app/Contents/Helpers/rclone"
  cp Packaging/THIRD_PARTY_NOTICES.txt "$app/Contents/Resources/THIRD_PARTY_NOTICES.txt"
  cp Packaging/Licenses/rclone-COPYING.txt "$app/Contents/Resources/Licenses/rclone-COPYING.txt"
  [ -f Packaging/AppIcon.icns ] && cp Packaging/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
  # Inside out, without --deep: the helper first, then the bundle that seals it.
  sign "$app/Contents/Helpers/rclone" --identifier ru.blhn.cloudmail.rclone
  sign "$app"
  codesign --verify --strict "$app"
}

if [[ "$MODE" == "--dev" ]]; then
  # Dev-only code (CLOUDMAIL_DEV) is compiled in here only; its own build folder keeps the release
  # build from being recompiled every time. This Mac's architecture only, for speed.
  swift_build --build-path .build/dev -Xswiftc -DCLOUDMAIL_DEV
  BIN="$(swift build -c release --build-path .build/dev -Xswiftc -DCLOUDMAIL_DEV --show-bin-path)/CloudMail"
  DEV="dist/$NAME Dev.app"
  rm -rf "$DEV"
  mkdir -p "$DEV/Contents"
  PL="$DEV/Contents/Info.plist"
  cp Packaging/Info.plist "$PL"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ru.blhn.cloudmail.dev" "$PL"
  /usr/libexec/PlistBuddy -c "Set :CFBundleName $NAME Dev" "$PL"
  # Must not hijack Finder services or double clicks on .mailcloud placeholders.
  /usr/libexec/PlistBuddy -c "Delete :NSServices" "$PL"
  /usr/libexec/PlistBuddy -c "Delete :UTExportedTypeDeclarations" "$PL"
  /usr/libexec/PlistBuddy -c "Delete :CFBundleDocumentTypes" "$PL"
  finish_bundle "$DEV" "$BIN"
  echo "Built: $PWD/$DEV"
  exit 0
fi

# One build per architecture (SwiftPM's multi-arch flag needs Xcode), joined with lipo.
ARCHS="${ARCHS:-arm64 x86_64}"
SLICES=()
for ARCH in ${=ARCHS}; do
  echo "Building $ARCH..."
  swift_build --triple "$ARCH-apple-macosx$MIN_OS" --build-path ".build/release-$ARCH"
  SLICES+=("$(swift build -c release --triple "$ARCH-apple-macosx$MIN_OS" --build-path ".build/release-$ARCH" --show-bin-path)/CloudMail")
done
mkdir -p .build/universal
BIN=".build/universal/CloudMail"
lipo -create "${SLICES[@]}" -output "$BIN"

APP="dist/$NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/Resources"
cp Packaging/Info.plist "$APP/Contents/Info.plist"
[ -f Packaging/PlaceholderIcon.icns ] && cp Packaging/PlaceholderIcon.icns "$APP/Contents/Resources/PlaceholderIcon.icns"
finish_bundle "$APP" "$BIN"
echo "Built: $PWD/$APP ($(lipo -archs "$APP/Contents/MacOS/CloudMail"), signed: $SIGN_IDENTITY)"

if [[ "$MODE" == "--run" ]]; then open "$APP"; fi

if [[ "$MODE" == "--install" ]]; then
  DEST="/Applications/$NAME.app"
  BUNDLE_ID="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" Packaging/Info.plist)"
  # Stop only the instance that runs from DEST (exact executable path; dev builds and copies
  # elsewhere share the process name CloudMail and are left alone).
  EXE="$DEST/Contents/MacOS/CloudMail"
  for PID in $(pgrep -x CloudMail 2>/dev/null || true); do
    [[ "$(LC_ALL=en_US.UTF-8 ps -o comm= -p "$PID" 2>/dev/null)" == "$EXE" ]] || continue
    kill "$PID" 2>/dev/null || true
    for i in {1..40}; do kill -0 "$PID" 2>/dev/null || break; sleep 0.25; done
  done
  # The previous bundle at DEST goes to the Trash, never a permanent delete.
  if [ -e "$DEST" ]; then mv "$DEST" "$HOME/.Trash/$NAME $(date +%Y%m%d-%H%M%S).app"; fi
  cp -R "$APP" "$DEST"
  open -g "$DEST"
  echo "Installed: $DEST"
  # An older copy with the same bundle id under another name (an earlier app name) is not touched:
  # two copies of one app confuse Launch Services, Finder services and login items.
  for OTHER in /Applications/*.app(N); do
    [[ "$OTHER" == "$DEST" ]] && continue
    [[ "$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$OTHER/Contents/Info.plist" 2>/dev/null)" == "$BUNDLE_ID" ]] || continue
    echo ""
    echo "Note: an older copy of this app is still installed: $OTHER"
    echo "      Quit it and move it to the Trash yourself; $DEST replaces it."
  done
fi

if [[ "$MODE" == "--release" ]]; then
  BASE="$DIST_NAME-$VERSION"
  ZIP="$BASE.zip"
  DMG="$BASE.dmg"
  for F in "dist/$ZIP" "dist/$DMG" dist/SHA256SUMS; do
    if [ -e "$F" ]; then mv "$F" "$HOME/.Trash/$(basename "$F") $(date +%Y%m%d-%H%M%S)"; fi
  done

  # ZIP: ditto keeps the Cyrillic name, permissions and the signature's extended attributes.
  (cd dist && ditto -c -k --sequesterRsrc --keepParent "$NAME.app" "$ZIP")

  # DMG: the app, a link to /Applications and a short note on the first launch.
  STAGE="$(mktemp -d .build/dmg-stage.XXXXXX)"
  ditto "$APP" "$STAGE/$NAME.app"
  ln -s /Applications "$STAGE/Программы"
  cat > "$STAGE/Как установить.txt" <<NOTE
Перетащите $NAME в папку «Программы» и откройте оттуда.

Если при первом запуске macOS пишет, что не может проверить разработчика:
Системные настройки → Конфиденциальность и безопасность → внизу «Открыть всё равно».
Кнопка появляется после попытки открыть приложение и висит около часа.

Подробнее: https://github.com/BLHN/mailru-cloud-mac#readme
NOTE
  hdiutil create -quiet -volname "$NAME $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO "dist/$DMG"
  rm -rf "$STAGE"

  (cd dist && shasum -a 256 "$ZIP" "$DMG" > SHA256SUMS)
  echo "Release files in $PWD/dist:"
  (cd dist && ls -l "$ZIP" "$DMG" SHA256SUMS && cat SHA256SUMS)
fi
