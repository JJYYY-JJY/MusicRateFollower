# Testing

## Automated tests

```sh
./script/test.sh
```

XCTest exercises production `Detection`, `PlaybackEvidence`, `DeviceState.target()`, and `AudioControl`. Controller tests replace HAL calls through `AudioAccess`; capability tests inject nominal and stream formats into the production target calculation. Neither simulates a real driver's property-write behavior.

Coverage includes:

- All 360 real-fixture records checked against reviewed item/bit-depth/rate/nil intervals, then fed to the simulated controller with explicit write and restoration expectations.
- Reversed startup history, exact live/history overlap, preload isolation, and gapless track transitions.
- Missing/invalid timestamps, timestamp collisions, late stop after preload, malformed critical messages, bounded duplicate retention, and fresh-evidence recovery. Unrelated records do not advance the evidence clock.
- Invalid evidence followed by an output change restores the old output without configuring the new one; complete new evidence is required before another target write.
- Discrete rates, continuous ranges, integer division, invalid inputs, and production nominal/physical/virtual capability intersection across multiple streams.
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

Cases use actual device capabilities and compare full production target formats, not nominal maxima. Algorithm correctness is checked separately with explicit unit-test expectations. Positive checks wait for full readback or a three-second deadline. Unavailable unsupported-source or alternate-format cases print `SKIP`. Cleanup checks UID and full readback and reports restoration failures.

End-to-end checks require playing lossless streams of known formats in Music and checking status logs, actual device formats, output switching, and restoration when Music quits.

Run the new Release executable without installing it, after normally stopping the installed helper. Record initial playback/default-output/format state. Correlate Music's current-item event and lossless report with `source-verified`, `write-start`, and `*-verified`/`restored` messages. Status timestamps include milliseconds; write and completion messages share device UID and transaction token. Measure item-change-to-evidence separately from write-start-to-readback. For a pending-quit check, request normal Music termination at alignment `write-start`; only count it as pending if `Music ended` precedes that transaction's verification. Restore the initial device and helper state afterwards.

## Earlier baseline

2026-09-05: macOS 27.0 (26A5425a), M5 Pro. All 18 automated tests passed. Backend tests passed for the built-in speakers, built-in 3.5 mm output, and Apple USB-C to 3.5 mm adapter. Live streaming verified the 192→96 kHz fallback, restoration after Music quit, and log subprocess cleanup.

At that point, actual system sleep/wake, physical device disconnection and reconnection, driver fault injection, Bluetooth, AirPlay, other macOS versions, and long-term unattended operation were unverified. Later lifecycle results are recorded below. Passing simulated fault tests does not establish coverage of those scenarios on real devices.

## Working-tree validation — 2026-09-05

macOS 27.0 (26A5425a), M5 Pro; only `BuiltInSpeakerDevice` (device 77, stream 78) was connected. Initial and final state: default built-in speakers, 44,100 Hz nominal/physical/virtual, stereo 32-bit float PCM (flags 9, 8 bytes per frame/packet, 1 frame per packet). Music was open and stopped before and after testing.

- **PASS:** the three initial regression tests failed on `b91978f` (stale target, history cancellation, unrelated-record clock advancement); all 25 automated tests pass after the changes.
- **PASS:** `swift build -c release -Xswiftc -Osize` and `git diff --check`.
- **PASS:** `./script/live_audio_test.sh --change-audio`: exact 44.1/48/88.2/96 kHz, 176.4→88.2 and 192→96 kHz, full-format readback, repeated-reconcile write suppression, first-snapshot restoration, and preservation of external changes through controller stop.
- **SKIP:** unsupported-source backend case: every source candidate has a usable integer-divided target on this device.
- **PASS:** real streaming of Eagles' “Hotel California” produced explicit 24-bit/192 kHz lossless evidence and verified 96 kHz output. Initial AAC reports did not authorize a target.
- **PASS:** externally changing the owned output to 48 kHz caused a yield at 14:28:48.291. Advancing to “Whole Lotta Love” produced fresh 24-bit/96 kHz evidence at 14:29:19.533 without reacquisition. Full HAL state remained 48 kHz after the track change and after Music quit.
- **PASS:** in a new Music session, normal quit restored the full original format: restore began at 14:31:18.247 and completed at 14:31:18.488 (241 ms).
- **PASS:** quitting Music during an unfinished alignment was observed, as detailed below. Log subprocesses ended on normal helper shutdown.
- **NOT RUN:** actual sleep/wake, physical unplug/replug, multi-output hardware switching (no second device connected), other drivers, Bluetooth/AirPlay, and long unattended runs. The earlier three-output backend record above remains historical; this run rechecked only built-in speakers.

### Observed timing

All times below are PDT (UTC−07:00) on 2026-09-05, converted from helper UTC timestamps where needed. Music event times came from unified logs; helper times mark receipt/processing, not audio latency measurements.

| Item | Current-item event | Complete evidence received | Evidence wait | HAL write → verified readback |
| --- | --- | --- | --- | --- |
| `I/LID.01` | 14:28:03.792718 | 14:28:04.247 | ~454 ms | 14:28:04.249 → 14:28:04.517, 268 ms |
| `I/XGM.01` | 14:30:43.330438 | 14:30:51.276 | ~7.946 s | 14:30:51.278 → 14:30:51.545, 267 ms |
| `I/HZC.01` | 14:32:26.446119 | 14:32:35.758 | ~9.312 s | 14:32:35.761 → 14:32:35.987, 226 ms |

The longer waits included initial AAC reports followed by a later explicit lossless report. They are source-evidence waits, not nine-second HAL transitions.

For `I/HZC.01`, a temporary stdout watcher requested normal termination via `NSRunningApplication.terminate()` immediately after `write-start`; no driver delay or fault was injected:

| Time | Observed event |
| --- | --- |
| 14:32:35.761 | Alignment begins, transaction `656621ED-F216-4A32-9564-B49269CD4C49`, 192→96 kHz |
| 14:32:35.763 | Normal quit request accepted |
| 14:32:35.949 | Follower receives Music termination while alignment remains pending |
| 14:32:35.987 | Original alignment verified; the controller proceeds to restoration |
| 14:32:35.988 | Restore begins, new transaction `DF24BE71-D2EA-4B6C-93AF-0FA848017D2D` |
| 14:32:36.398 | Original 44.1 kHz full format restored and verified |

The installed executable was not replaced (SHA-256 before/after: `768f4d98f28f86710f8832fdb58bb108c2c6b94541a7032a7de10738e63670c0`). Its LaunchAgent was restarted after the temporary Release process exited. Temporary probes and watcher artifacts were removed; no commit or push was made.

## Interactive lifecycle validation — 2026-09-05

Using the same working-tree Release build. Initial default: `BuiltInHeadphoneOutputDevice`, 48 kHz; speakers: `BuiltInSpeakerDevice`, 44.1 kHz. An independent HAL listener records full device formats alongside the follower log. Times here are UTC.

- **PASS:** backend capability, repeated-write suppression, external takeover, and full-snapshot restoration checks on both the built-in headphone output and speakers. Neither device had an unsupported source among the six candidates; those cases were explicitly skipped.
- **PASS:** physical unplug during 24-bit/192 kHz playback (`I/OSH.01`). At 21:49:06.778 the controller yielded the disconnected headphone UID. The default output changed to speakers; the same item's playback evidence remained valid before the speaker write at 21:49:06.794. Full 96 kHz output was verified at 21:49:07.064. The user confirmed sound continued through speakers.
- **PASS:** physical replug. The headphone UID returned with its driver-retained 96 kHz format. The controller did not reacquire that yielded UID in the same Music session. Speaker restoration began at 21:50:13.787 and full original 44.1 kHz was verified at 21:50:14.007. The user confirmed sound returned to headphones.
- **PASS:** real sleep/wake in a fresh Music session, with headphone baseline reset to its initial 48 kHz to remove prior unplug-induced yielding. The follower invalidated evidence at 21:52:23.817 and again at 21:52:40.833. `pmset` independently recorded Clamshell Sleep at 21:52:28, DarkWake at 21:52:31, and FullWake at 21:52:40. The user confirmed playback remained paused on wake.
- **PASS:** output switching without fresh evidence after wake. Selecting speakers at 21:53:36 caused only headphone restoration to 48 kHz (verified at 21:53:36.632); speakers remained at 44.1 kHz. Selecting headphones again did not authorize a target write.
- **PASS:** incomplete versus complete fresh evidence. Resuming `I/BXF.01` at 21:53:57 produced positive-rate and lossless-format reports but no new current-item event; the follower correctly retained no target and headphones stayed at 48 kHz. Switching to “Little Lies” (`I/FPW.01`) supplied current-item, positive-rate, and 16-bit/44.1 kHz format evidence. The target was accepted at 21:54:09.990, written at 21:54:09.992, and verified at 21:54:10.148.
- **PASS:** final normal Music exit restored headphones to their full original 48 kHz format at 21:54:45.638; speakers remained at their original 44.1 kHz. Default output remained headphones. Music was reopened stopped and the original installed LaunchAgent was restored after the test helper exited. Test observers, probes, and scratch logs were removed after recording these results.

This also establishes the conservative resume behavior: after sleep, resuming the same item can leave the source unknown until a new current-item event arrives, even if Music emits a new format report. The helper does not reuse the pre-sleep current-item association. Physical replug likewise does not override a session-level yield; a new Music session is required to regain control of that UID.

Current remaining hardware boundaries: other drivers/devices, USB-device replug (this session used the built-in analog headphone output), Bluetooth/AirPlay, injected driver faults, repeated/long-duration sleep cycles, and long unattended operation. No installation, commit, or push was performed during these checks.

## Installation acceptance — 2026-09-05

After explicit installation authorization, `./script/install.sh` successfully built and installed the working-tree Release executable, stripped and ad-hoc signed it, and registered `gui/501/local.MusicRateFollower`. `codesign --verify --strict` passed. The running process was the installed executable under `~/Library/Application Support/MusicRateFollower/`, launched by launchd (PID 62335, parent PID 1). Installed SHA-256: `9e5738405cc0a20ea51c23c491d76d3f8620403bc03eac73ea15e4e0b2d14c64`.

- **PASS:** installed helper observed Music launching and completed bootstrap at 14:56:51.018 PDT.
- **PASS:** real 24-bit/192 kHz playback (`I/RTE.01`) was recognized at 14:57:10.711. Headphone alignment began at 14:57:10.715 and full 96 kHz output was verified at 14:57:10.882. An independent device query agreed.
- **PASS:** Music termination was observed at 14:57:26.454. Headphone restoration began at 14:57:26.457 and full original 48 kHz was verified at 14:57:26.573. Speakers remained at 44.1 kHz; default output remained headphones.
- **PASS:** the installed helper remained running and waiting for Music, with no child log processes after Music exited. The LaunchAgent has `RunAtLoad=true`; a fresh login was not exercised.

Installation is complete. Source changes remain uncommitted; no push was made. Hardware coverage boundaries above are unchanged.
