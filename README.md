# MusicRateFollower

A macOS background tool that adjusts the default output device to the source sample rate of Apple Music lossless streams. When Music quits, it restores settings on devices still under its control.

## Requirements

- macOS 27: the current log parser is enabled only on this version.
- Swift 6 / Xcode toolchain.
- Apple's Music.app.

Uses system frameworks with no third-party runtime dependencies, windows, or menu bar icon.

## Installation and usage

Run from the repository root:

```sh
./script/install.sh
```

The script builds a Release executable, installs it in `~/Library/Application Support/MusicRateFollower/`, and registers a user LaunchAgent. The helper starts at login; opening Music normally activates detection.

```sh
# List output devices
"$HOME/Library/Application Support/MusicRateFollower/MusicRateFollower" --devices

# View status logs
log show --last 5m --style compact --predicate 'subsystem == "local.MusicRateFollower"'

# Stop and restore device settings
launchctl kill SIGTERM "gui/$(id -u)/local.MusicRateFollower"

# Start again
launchctl kickstart "gui/$(id -u)/local.MusicRateFollower"

# Uninstall
./script/uninstall.sh
```

## Behavior

- Waits for system events while Music is not running, with no log subprocess or process/device polling.
- Associates the current playback item with an explicit lossless format report. Leaves settings unchanged when evidence is insufficient.
- Matches the source sample rate when supported; otherwise selects the highest supported rate equal to the source rate divided by a positive integer. For example, 192 kHz can fall back to 96 or 48 kHz. Selection uses device capabilities, with no model-specific rules.
- Keeps a format that can accommodate 24-bit PCM precision, without switching bit depth for each track. Reads settings back to verify changes and distinguishes an exact match from a lower-rate fallback.
- Saves each device's settings by UID before its first modification. Pausing does not restore settings; switching outputs, quitting Music, or stopping the helper normally restores devices still under its control.
- Relinquishes control after an external change or fault rollback and leaves that device alone for the rest of the Music session. Does not write if a required listener cannot be registered.
- Sleep and wake clear playback evidence. Resuming the same track can leave following inactive even with new playback-rate and lossless-format reports, until a new current-item event completes fresh playback evidence. Changing tracks can supply that evidence; simply pressing Play is not guaranteed to resume following.
- Reconnecting a device does not reacquire its UID if control was relinquished during the current Music session. Quit and reopen Music to start a new session; valid playback evidence is still required before following resumes.

Snapshots are held only in memory, so the helper cannot restore settings immediately after it is force-killed. Log formats may change with system updates; missing or invalid historical evidence causes detection to wait for new events. Core Audio exposes neither the identity of the writer nor atomic conditional writes, so the helper cannot detect another application taking control without changing values or eliminate every race between checking and writing. Sample rate alignment does not establish bit-perfect playback throughout the audio chain.

## Development

```sh
./script/test.sh
swift build -c release -Xswiftc -Osize
./script/build_and_run.sh --diagnose
```

`--diagnose` only reports proposed settings; `build_and_run.sh` first stops any existing instance normally. Automated tests use a simulated HAL and do not modify real audio devices. See [docs/testing.md](docs/testing.md) for hardware test instructions and coverage.

After correcting HAL write order, the lifeme HiFi Audio Pro passed backend format switching and snapshot restoration, plus real 44.1→48→44.1 kHz playback and restoration to its original 16-bit physical format. See the test record for the earlier failure and the limits of this device-specific verification.

Format the code:

```sh
xcrun swift-format format --in-place --recursive Package.swift Sources Tests
```
