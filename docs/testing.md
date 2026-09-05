# Testing

## Automated tests

```sh
./script/test.sh
```

XCTest exercises the production `Detection`, `PlaybackEvidence`, and `AudioControl` implementations. Tests replace HAL calls through `AudioAccess` and supply device state, listener failures, and write timing.

Coverage includes:

- A real log fixture, playback item association, preload isolation, and gapless track transitions.
- Discrete sample rates, continuous ranges, integer division, missing candidates, and invalid inputs.
- Partial write failures, timeout rollback, notification reentrancy, and external takeover.
- Listener prerequisites after a transient read failure and transaction token isolation during shutdown.
- Historical replay cancellation, evidence invalidation boundaries, and simulated sleep/wake events.

Tests require AppKit and CoreAudio on macOS. CI runs only automated tests and a Release build.

## Hardware tests

Pause Music and stop the installed helper normally:

```sh
launchctl kill SIGTERM "gui/$(id -u)/local.MusicRateFollower"
./script/live_audio_test.sh --change-audio
```

The script changes the default output and sample rates, then restores settings from snapshots taken before testing. It supplies test targets to verify device control; it does not verify source format detection.

End-to-end checks require playing lossless streams of known formats in Music and checking status logs, actual device formats, output switching, and restoration when Music quits.

## Verified scope

2026-09-05: macOS 27.0 (26A5425a), M5 Pro. All 18 automated tests passed. Backend tests passed for the built-in speakers, built-in 3.5 mm output, and Apple USB-C to 3.5 mm adapter. Live streaming verified the 192→96 kHz fallback, restoration after Music quit, and log subprocess cleanup.

Actual system sleep/wake, physical device disconnection and reconnection, driver fault injection, Bluetooth, AirPlay, other macOS versions, and long-term unattended operation remain unverified. Passing simulated fault tests does not establish coverage of those scenarios on real devices.
