#!/bin/bash
set -euo pipefail
label=local.MusicRateFollower
support="$HOME/Library/Application Support/MusicRateFollower"
launchctl kill SIGTERM "gui/$(id -u)/$label" 2>/dev/null || true
for attempt in {1..40}; do
    pgrep -x MusicRateFollower >/dev/null || break
    sleep 0.1
done
if pgrep -x MusicRateFollower >/dev/null; then echo 'Helper is still restoring; uninstall cancelled.' >&2; exit 1; fi
launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$label.plist" "$support/MusicRateFollower" "$support/instance.lock"
rmdir "$support" 2>/dev/null || true
echo 'Uninstalled MusicRateFollower.'
