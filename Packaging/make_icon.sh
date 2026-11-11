#!/bin/zsh
# Regenerates Packaging/AppIcon.icns and Packaging/PlaceholderIcon.icns (needs only Command Line Tools).
set -euo pipefail
cd "$(dirname "$0")"
TMP="$(mktemp -d)"
swiftc -O -o "$TMP/make_icon" make_icon.swift
"$TMP/make_icon" "$TMP"
iconutil -c icns "$TMP/AppIcon.iconset" -o AppIcon.icns
iconutil -c icns "$TMP/PlaceholderIcon.iconset" -o PlaceholderIcon.icns
rm -rf "$TMP"
echo "AppIcon.icns and PlaceholderIcon.icns updated"
