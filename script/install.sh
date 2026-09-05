#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
label=local.MusicRateFollower
support="$HOME/Library/Application Support/MusicRateFollower"
plist="$HOME/Library/LaunchAgents/$label.plist"
swift build -c release -Xswiftc -Osize
binary="$(swift build -c release --show-bin-path)/MusicRateFollower"
launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
pkill -TERM -x MusicRateFollower 2>/dev/null || true
for attempt in {1..30}; do
    pgrep -x MusicRateFollower >/dev/null || break
    sleep 0.1
done
if pgrep -x MusicRateFollower >/dev/null; then echo 'Helper is still restoring; installation cancelled.' >&2; exit 1; fi
mkdir -p "$support" "$(dirname "$plist")"
install -m 755 "$binary" "$support/MusicRateFollower"
strip -S -x "$support/MusicRateFollower"
codesign --force --sign - "$support/MusicRateFollower"
/usr/libexec/PlistBuddy -c 'Clear dict' -c 'Add :Label string local.MusicRateFollower' \
  -c 'Add :ProgramArguments array' -c "Add :ProgramArguments:0 string $support/MusicRateFollower" \
  -c 'Add :RunAtLoad bool true' -c 'Add :KeepAlive bool false' \
  -c 'Add :LimitLoadToSessionType string Aqua' -c 'Add :ProcessType string Background' \
  -c 'Add :ExitTimeOut integer 5' -c 'Add :AbandonProcessGroup bool false' "$plist"
chmod 644 "$plist"
launchctl bootstrap "gui/$(id -u)" "$plist"
echo "Installed $support/MusicRateFollower"
