#!/bin/zsh
# Visual QA of the dev bundle. Builds nothing: run ./build.sh --dev first.
# Usage: Packaging/dev/devshots.sh <name> [--frames N] [dev flags...]
#   Launches "dist/<name> Dev.app" in the background (never activated) with the dev flags,
#   waits 4 s and captures the main window to $DEVSHOTS_DIR/<name>.png (default docs/screenshots).
#   With --frames N it instead captures N frames about 120 ms apart into
#   $DEVSHOTS_DIR/frames/<name>-NN.png, starting right before the --dev-play moment (2 s after launch).
#   DEVSHOTS_WAIT=<seconds> waits longer before the single shot (e.g. a real download to finish).
#   DEVSHOTS_ENV="VAR=value ..." passes environment variables to the app, e.g.
#   "RCLONE_CONFIG=/dev/null CLOUDMAIL_DEV_SUPERVISOR_STATUS=/nonexistent" shows the app as on a Mac
#   without an rclone remote and without the background supervisor.
#   Add CLOUDMAIL_DEV_DEMO_NO_SUPERVISOR=1 to keep «Копия Мака» out of the demo too (README shots).
#   CLOUDMAIL_DEV_DEMO_ACCOUNT=example@mail.ru shows the demo as signed in with that invented address.
#   Then it quits its own dev instance by pid (never any other process).
# Example: Packaging/dev/devshots.sh done --frames 24 --dev-demo --dev-appearance dark --dev-play done
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT=${DEVSHOTS_DIR:-docs/screenshots}

[[ $# -ge 1 ]] || { echo "usage: $0 <name> [--frames N] [dev flags...]" >&2; exit 2; }
name=$1; shift
frames=0
args=()
while (( $# )); do
  if [[ $1 == --frames ]]; then frames=$2; shift 2; else args+=("$1"); shift; fi
done

# The window remembers its frame: start every shot at the default size unless asked otherwise.
[[ " ${args[*]} " == *" --dev-size "* ]] || args+=(--dev-size 920x600)

NAME="$(/usr/libexec/PlistBuddy -c "Print :CFBundleName" Packaging/Info.plist)"
APP="dist/$NAME Dev.app"
PATTERN="$NAME Dev.app/Contents/MacOS/CloudMail"
[[ -d $APP ]] || { echo "no $APP, run ./build.sh --dev" >&2; exit 1; }

# Window lister (CGWindowList, no screen recording prompt for window numbers).
WINID=${WINID:-.build/devtools/winid}
if [[ ! -x $WINID ]]; then
  mkdir -p .build/devtools
  swiftc -O -o .build/devtools/winid Packaging/dev/winid.swift
  WINID=.build/devtools/winid
fi

before=" $( (pgrep -f "$PATTERN" || true) | tr "\n" " ") "
envargs=()
for kv in ${=DEVSHOTS_ENV:-}; do envargs+=(--env "$kv"); done
open -n -g "${envargs[@]}" "$APP" --args "${args[@]}"

pid=""
for _ in {1..50}; do
  for p in $(pgrep -f "$PATTERN"); do
    [[ $before == *" $p "* ]] || pid=$p
  done
  [[ -n $pid ]] && break
  sleep 0.1
done
[[ -n $pid ]] || { echo "dev app did not start" >&2; exit 1; }

# Main window: the largest normal-layer window of that process.
main_window() {
  "$WINID" "$pid" | awk '$6 == 0 { w=$(NF-2); h=$NF; if (w*h > best) { best=w*h; id=$1 } } END { if (id) print id }'
}
win=""
for _ in {1..80}; do
  win=$(main_window || true)
  [[ -n $win ]] && break
  sleep 0.1
done
if [[ -z $win ]]; then
  kill "$pid" 2>/dev/null || true
  echo "no window for pid $pid" >&2; exit 1
fi

mkdir -p "$OUT/frames"
if (( frames > 0 )); then
  # --dev-play fires 2 s after launch; start a little before it.
  sleep 1.7
  win=$(main_window)
  for i in $(seq 1 "$frames"); do
    screencapture -x -o -l "$win" "$OUT/frames/$name-$(printf %02d "$i").png" &
    sleep 0.12
  done
  wait
  echo "frames: $OUT/frames/$name-01..$(printf %02d "$frames").png (window $win, pid $pid)"
else
  sleep "${DEVSHOTS_WAIT:-4}"
  win=$(main_window)
  screencapture -x -o -l "$win" "$OUT/$name.png"
  echo "shot: $OUT/$name.png (window $win, pid $pid)"
fi

kill "$pid" 2>/dev/null || true
