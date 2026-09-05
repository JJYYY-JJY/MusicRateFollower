#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "${1:-}" != --change-audio ]]; then
    echo 'This test changes default output and formats, then restores its snapshots.'
    echo 'Pause Music, stop MusicRateFollower, then run with --change-audio.'
    exit 64
fi
if pgrep -x MusicRateFollower >/dev/null; then echo 'Stop MusicRateFollower first.' >&2; exit 1; fi
scratch=$(mktemp -d /tmp/MusicRateFollower-live.XXXXXX)
trap 'rm -rf "$scratch"' EXIT
swiftc -Osize Sources/MusicRateFollower/Audio.swift Sources/MusicRateFollower/Detection.swift Tests/Manual/backend.swift -o "$scratch/live-test"
"$scratch/live-test"
