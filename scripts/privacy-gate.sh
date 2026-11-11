#!/bin/bash
# Privacy gate: fails when the tree (or a built app) contains personal data that must never be
# published: absolute home paths, real e-mail addresses, private files, metadata in screenshots,
# big files.
#
# Usage: scripts/privacy-gate.sh                 check the working tree (run before every push; CI runs it)
#        scripts/privacy-gate.sh --bundle <app>  check the strings of a built app's binaries
#
# Private patterns: words that are personal to you (names, hostnames, folder names) do not belong in
# this script, since publishing the list would publish them. Put them in a file that is never
# committed, by default .git/info/privacy-patterns (the repository's common git dir, so it also
# works in a worktree), or point PRIVACY_PATTERNS_FILE at one. Format: one extended regular
# expression per line; empty lines and lines starting with '#' are ignored; a line
# "allow: <regex>" names a token that is removed from a line before the patterns are matched again.
# Patterns are matched against file contents and against file and folder names.
#
# BSD grep (macOS) has no lookahead, so every text check runs in two passes: pass 1 finds the lines
# that match a forbidden pattern; pass 2 removes the allowed tokens from exactly those lines and
# matches again. Whatever is still left fails the gate.
set -euo pipefail

# Resolve the patterns file before leaving the caller's directory.
PATTERNS_FILE="${PRIVACY_PATTERNS_FILE:-}"
if [[ -n "$PATTERNS_FILE" && "$PATTERNS_FILE" != /* ]]; then PATTERNS_FILE="$PWD/$PATTERNS_FILE"; fi
cd "$(dirname "$0")/.."
if [[ -z "$PATTERNS_FILE" ]]; then
  PATTERNS_FILE="$(git rev-parse --path-format=absolute --git-path info/privacy-patterns 2>/dev/null \
    || echo .git/info/privacy-patterns)"
fi

# Always forbidden: absolute home paths.
HOME_PATHS='/Users/'
# Never matches anything: the empty alternative for "no private patterns".
NEVER='a^'

PRIVATE="$NEVER"
PRIVATE_ALLOWED="$NEVER"
if [[ -n "${PRIVACY_PATTERNS_FILE:-}" && ! -r "$PATTERNS_FILE" ]]; then
  echo "privacy-gate: PRIVACY_PATTERNS_FILE does not exist: $PATTERNS_FILE" >&2; exit 2
fi
if [[ -r "$PATTERNS_FILE" ]]; then
  count=0
  while IFS= read -r p || [[ -n "$p" ]]; do
    p="${p%$'\r'}"
    [[ -z "${p//[[:space:]]/}" || "$p" == \#* ]] && continue
    if [[ "$p" == allow:* ]]; then
      p="${p#allow:}"; p="${p#"${p%%[![:space:]]*}"}"
      PRIVATE_ALLOWED="$PRIVATE_ALLOWED|($p)"
    else
      PRIVATE="$PRIVATE|($p)"
      count=$((count + 1))
    fi
  done < "$PATTERNS_FILE"
  echo "privacy-gate: $count private pattern(s) loaded"
else
  echo "privacy-gate: no private patterns file (optional)"
fi

# E-mail addresses: only invented ones and GitHub noreply addresses may appear.
EMAIL='[A-Za-z0-9._%+*-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}'
EMAIL_ALLOWED='(example|name|ivan|Ivan|i\*\*\*|test|you)@(mail\.ru|example\.(com|org))|[0-9]+\+[A-Za-z0-9-]+@users\.noreply\.github\.com|noreply@anthropic\.com|@(mail|bk|inbox|list|internet)\.ru'

fail=0
report() { echo "privacy-gate: $1" >&2; fail=1; }

# check_lines <label> <pattern> <allowed>: reads "file:line:text" lines on stdin.
check_lines() {
  local label="$1" pattern="$2" allowed="$3" line text
  while IFS= read -r line; do
    text="$(printf '%s\n' "$line" | sed -E "s/${allowed//\//\\/}//g")"
    if printf '%s\n' "$text" | grep -qE -- "$pattern"; then
      report "$label: $line"
    fi
  done
}

if [[ "${1:-}" == "--bundle" ]]; then
  APP="${2:?usage: $0 --bundle <path to .app>}"
  BIN="$APP/Contents/MacOS/CloudMail"
  [[ -f "$BIN" ]] || { echo "privacy-gate: no binary at $BIN" >&2; exit 2; }
  FORBIDDEN="$HOME_PATHS|$PRIVATE"
  check_lines "binary" "$FORBIDDEN" "$PRIVATE_ALLOWED" < <(strings -a "$BIN" | grep -nE -- "$FORBIDDEN" | sed "s|^|CloudMail:|" || true)
  check_lines "binary e-mail" "$EMAIL" "$EMAIL_ALLOWED" < <(strings -a "$BIN" | grep -noE -- "$EMAIL" | sed "s|^|CloudMail:|" || true)
  if grep -aqE -- '_hasKeyAppearance' "$BIN"; then report "binary: dev-only AppKit selector in a release build"; fi
  check_lines "Info.plist" "$FORBIDDEN" "$PRIVATE_ALLOWED" < <(/usr/libexec/PlistBuddy -c "Print" "$APP/Contents/Info.plist" \
    | grep -nE -- "$FORBIDDEN" | sed "s|^|Info.plist:|" || true)
  if (( fail )); then echo "privacy-gate: FAILED (bundle)" >&2; exit 1; fi
  echo "privacy-gate: bundle clean"
  exit 0
fi

EXCLUDES=(--exclude-dir=.git --exclude-dir=.build --exclude-dir=dist --exclude-dir=.swiftpm)
PRUNE=(\( -path ./.git -o -path ./.build -o -path ./dist -o -path ./.swiftpm \) -prune -o)

# 1. Text: home paths (this script names the pattern itself) and private patterns (everywhere).
check_lines "home path" "$HOME_PATHS" "$NEVER" < <(grep -rInE "${EXCLUDES[@]}" --exclude=privacy-gate.sh -- "$HOME_PATHS" . || true)
check_lines "private pattern" "$PRIVATE" "$PRIVATE_ALLOWED" < <(grep -rInE "${EXCLUDES[@]}" -- "$PRIVATE" . || true)

# 2. Text: e-mail addresses.
check_lines "e-mail" "$EMAIL" "$EMAIL_ALLOWED" < <(grep -rInoE "${EXCLUDES[@]}" -- "$EMAIL" . || true)

# 3. Names of files and folders that belong to a private working copy only, and names that match
#    a private pattern.
while IFS= read -r f; do report "file must not be published: $f"; done < <(
  find . "${PRUNE[@]}" \
    \( -name 'HANDOFF*' -o -name 'SPEC-*' -o -name 'mockups' -o -name '*.mov' -o -name '*.mp4' \
       -o -name 'rclone.conf' -o -name '*.p12' -o -name '*.pem' -o -name '.env' \) -print)
check_lines "file name" "$PRIVATE" "$PRIVATE_ALLOWED" < <(find . "${PRUNE[@]}" -print | sed 's|$|:0:name|' \
  | grep -E -- "$PRIVATE" || true)

# 4. Images: no EXIF, XMP or text chunks (camera, software, user names, paths).
while IFS= read -r img; do
  if LC_ALL=C grep -aqE 'eXIf|iTXt|tEXt|zTXt|<x:xmpmeta|Exif' "$img"; then
    report "image has metadata (strip it): $img"
  fi
done < <(find . "${PRUNE[@]}" \( -name '*.png' -o -name '*.jpg' -o -name '*.jpeg' \) -print)

# 5. Size: nothing over 5 MB in the tree.
while IFS= read -r big; do report "file over 5 MB: $big"; done < <(
  find . "${PRUNE[@]}" -type f -size +5M -print)

if (( fail )); then echo "privacy-gate: FAILED" >&2; exit 1; fi
echo "privacy-gate: clean"
