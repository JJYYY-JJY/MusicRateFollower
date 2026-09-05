#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# The single-instance lock prevents a second owner during rebuild/shutdown.
pkill -TERM -x MusicRateFollower 2>/dev/null || true
for attempt in {1..30}; do
    pgrep -x MusicRateFollower >/dev/null || break
    sleep 0.1
done
if pgrep -x MusicRateFollower >/dev/null; then
    echo 'Existing helper has not stopped; refusing a second instance.' >&2
    exit 1
fi
swift build -c release -Xswiftc -Osize
binary="$(swift build -c release --show-bin-path)/MusicRateFollower"
case "${1:-run}" in
    run) exec "$binary" ;;
    --diagnose) exec "$binary" --diagnose ;;
    --debug) exec lldb -- "$binary" ;;
    *) echo 'usage: build_and_run.sh [--diagnose|--debug]' >&2; exit 64 ;;
esac
