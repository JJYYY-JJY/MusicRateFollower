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
- Production property-write order with deferred driver completion: rate/virtual writes renegotiate physical bit depth, and alignment, restoration, and virtual-only updates must still reach the full intended format.
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

Cases use actual device capabilities and compare full production target formats, not nominal maxima. Each sequential target is calculated from a fresh device read immediately before setting the source, because selection preserves the current physical format when it remains suitable. The initial snapshot is retained for restoration; the external-takeover target is calculated from a fresh read after restoration. Algorithm correctness is checked separately with explicit unit-test expectations. Positive checks wait for full readback or a three-second deadline. Unavailable unsupported-source or alternate-format cases print `SKIP`. Cleanup checks UID and full readback and reports restoration failures.

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

## USB DAC acceptance — 2026-09-05

Working tree based on `15eda7f`, with test and documentation changes only; macOS 27.0 (26A5425a). Times below are UTC. Target: **lifeme HiFi Audio Pro**, manufacturer TTGK Technology Co.,Ltd, USB transport, UID `AppleUSBAudioEngine:TTGK Technology Co.,Ltd:lifeme HiFi Audio Pro:1100000:1` (device 85, stream 86 at test start). This is a USB DAC, distinct from the built-in analog headphone output in the earlier lifecycle record.

Initial readback at 22:35:43.506: default output `BuiltInSpeakerDevice` (78), 48 kHz nominal/physical/virtual, stereo 32-bit float (flags 9, 8 bytes per frame/packet). DAC: 48 kHz nominal/physical/virtual, stereo 16-bit signed packed physical PCM (flags 12, 4 bytes per frame/packet), 32-bit float virtual PCM (flags 9, 8 bytes per frame/packet); both have one frame per packet. Music was open and stopped. The installed helper was running under launchd and was stopped normally before hardware writes.

- **PASS:** all 26 automated tests, including explicit full-format expectations for 44.1 kHz/32-bit → 48 kHz/24-bit → 88.2 kHz/24-bit and direct 44.1 kHz/32-bit → 88.2 kHz/32-bit selection.
- **PASS:** Release build, independent compilation of the manual backend, Swift format lint, and `git diff --check`.
- **FAIL:** `./script/live_audio_test.sh --change-audio`. The first DAC alignment to 44.1 kHz began at 22:35:56, transaction `8CD6148A-C0C0-4AD2-8623-2E6AEBEBDAE5`, then reported `yielded: external format change`. No full-format verification or later backend case passed. The cleanup reported `snapshot restore did not settle` and the executable exited with a top-level Swift error (script status 133). The yield message alone does not establish that another application wrote the device.
- **FAIL, recovered separately:** backend cleanup restored the default output to speakers but left the DAC at 48 kHz with 32-bit physical PCM instead of the initial 16-bit format. A temporary recovery probe checked the UID, set 48 kHz nominal then the original physical format, and verified the complete initial DAC state at 22:36:33.765. Speakers remained unchanged. This recovery does not make backend restoration a pass.

An independent HAL listener was started before real playback. The default output was set to the DAC and the working-tree Release follower was started at 22:36:50.850.

- **PASS:** “World's End Loneliness (Full Ver.)” by 打打だいず supplied 24-bit/48 kHz evidence (`I/RSK.01`) at 22:37:18.684. Alignment transaction `99A1B2CD-3B1F-400B-A325-0B2A8535EC9E` ran from 22:37:18.688 to 22:37:18.838 (150 ms). Independent readback showed 48 kHz/24-bit signed packed physical PCM (6 bytes per frame/packet), with 32-bit float virtual PCM. No repeated alignment write occurred before the next track.
- **FAIL:** advancing to “Abstruse Dilemma” by 打打だいず & Ashrount supplied 24-bit/44.1 kHz evidence (`I/PSG.01`) at 22:37:43.070. Transaction `C8E0C0FF-03E9-4BA5-B9A3-14A2103643A7` began at 22:37:43.072; the expected physical format was 24-bit, preserved from the preceding track. Independent readback at 22:37:43.773 instead showed 44.1 kHz/32-bit signed packed physical PCM (8 bytes per frame/packet), with matching-rate 32-bit float virtual PCM. The follower yielded at 22:37:43.787. Fresh evidence for the same item at 22:37:44.138 did not cause reacquisition. Nominal alignment alone is not a full-format pass.
- **PASS, control boundary only:** normal Music termination at 22:38:23.444 did not restore the already-yielded DAC; it remained 44.1 kHz/32-bit. This preserved the session-level yield but did not recover the initial 48 kHz/16-bit device state.

- **PASS:** fresh Music session (PID 72856) accepted 16-bit/44.1 kHz evidence for “虹色の光りの中で” (`I/OZO.01`) at 22:38:37.897 and reported `aligned-existing`. The DAC baseline for this session was 44.1 kHz/32-bit, not the acceptance session's original 48 kHz/16-bit.
- **PASS, evidence boundary:** actual sleep/wake with the DAC connected. The follower invalidated evidence at 22:39:16.594 and 22:39:29.088; `pmset` recorded Clamshell Sleep at 22:39:21, DarkWake at 22:39:24, and FullWake at 22:39:29. The user reported no automatic playback resume, confirmed by Music's paused state. Full DAC format remained 44.1 kHz/32-bit.
- **PASS, evidence boundary; following remained inactive:** continuing the same item produced a positive audio-rate event at 22:40:03.781255 and a 16-bit/44.1 kHz lossless report at 22:40:03.848030, but no new current-item event. No target was authorized. Selecting speakers at 22:40:19.754 left them at 48 kHz; selecting the DAC again at 22:40:27.885 left it at 44.1 kHz. This session had no outstanding modified-device lease at the time, so it did not exercise restoration on the post-wake output switch.
- **PASS, following recovered:** advancing to “World's End Loneliness (Full Ver.)” (`I/IFE.01`) supplied fresh evidence. Transaction `D9167C36-2ABF-4D43-A4FC-68938A55666B` verified 48 kHz output at 22:40:28.841; independent full readback agreed with 32-bit physical and virtual PCM. No second alignment write followed the repeated `aligned-existing` statuses. Unlike the failed 24-bit transition above, this transition began with a 32-bit physical format and retained it.

- **PASS, control boundary:** physical USB unplug at 22:40:57.066 yielded the DAC as `disconnected/unreadable`. Default output changed to speakers at their existing 48 kHz; the user confirmed sound continued through speakers. The observer saw the DAC return at 22:41:37.564 with the same UID, initially 48 kHz/16-bit, then 48 kHz/32-bit at 22:41:37.722. The user confirmed automatic audio routing back to the DAC. No follower alignment write occurred on replug; the physical-format change must not be attributed to a follower write. Audio object IDs changed during enumeration, so comparison used UID and freshly read IDs.
- **PASS, control boundary; following remained inactive:** after replug, a new 24-bit/44.1 kHz item (`I/UHC.01`, “Abstruse Dilemma”) was verified at 22:42:06.024, but the yielded DAC remained at 48 kHz/32-bit with no new write. Playback routing recovered; sample-rate following did not.
- **PASS, following recovered in a new session:** Music was quit normally and reopened (PID 73843). Fresh 16-bit/44.1 kHz evidence (`I/LMK.01`, “虹色の光りの中で”) at 22:42:43.484 authorized alignment. Transaction `33BDD7E8-BE66-4AE9-A0EE-DB01507742BD` ran from 22:42:43.489 to 22:42:44.339 (850 ms). Independent readback confirmed 44.1 kHz/32-bit physical and virtual formats.
- **PASS, restoration of this session's snapshot:** Music ended at 22:42:51.772. Restore transaction `8656CAD7-8CF7-41D4-AB54-7D400D0CB715` ran from 22:42:51.775 to 22:42:51.978 (203 ms), restoring the full 48 kHz/32-bit state from this new Music session. This does not establish restoration from a 16-bit baseline, which failed in the backend run.
- **PASS, final cleanup:** the temporary follower exited normally. Default output was returned to `BuiltInSpeakerDevice`; the UID-checked recovery probe restored the DAC's original 48 kHz/16-bit physical and 32-bit float virtual state, with full verification at 22:43:26.262. Speakers retained their full initial 48 kHz format. Music was reopened stopped, and the original installed LaunchAgent was restarted (PID 74143, parent 1). Installed SHA-256 remained `9e5738405cc0a20ea51c23c491d76d3f8620403bc03eac73ea15e4e0b2d14c64`. Temporary probes, observers, and scratch logs were removed after recording these results.

**Acceptance result: failed overall for this DAC.** The sequential manual expectation bug is fixed and automated checks pass, but real 24-bit physical transitions and backend restoration exposed a separate hardware-path failure. Production code was not changed in this test/documentation task. Higher-rate and integer-divided backend cases, duplicate suppression across the full backend sequence, and external-takeover backend checks were not reached after the first failure. Bluetooth/AirPlay, other USB DACs, repeated sleep/replug cycles, and long unattended use remain unverified. No new executable was installed, and no commit or push was made.

## USB write-order fix validation — 2026-09-05

Same macOS build and lifeme DAC UID as above. The original failure record is retained; the results below supersede its format-switching and restoration failure for the corrected working-tree build. Initial state: default speakers at their full original 48 kHz/32-bit float format; DAC at 48 kHz/16-bit signed packed physical PCM and 32-bit float virtual PCM. Music was open and stopped; the installed helper was stopped normally before testing. Times are UTC.

The isolated original write sequence (physical → nominal → virtual) reproduced a final 44.1 kHz/32-bit physical format instead of the requested 24-bit. Immediate reads after setters still showed the old state, confirming that return from a setter is not completion. Submitting physical last restored the complete initial 16-bit snapshot. The shared production writer now submits nominal and virtual changes before physical formats, including resubmitting a physical format that matched the starting snapshot when an earlier write could renegotiate it. Target selection, full-format verification, transaction timeouts, evidence boundaries, and external-takeover checks were not relaxed.

- **PASS:** all 27 automated tests. The new test calls the production writer with injected HAL operations that defer completion and renegotiate physical PCM to 32-bit. It checks complete final formats for alignment to 24-bit, restoration to 16-bit, and a virtual-only change whose physical format initially matched. Restoring the old write order made this regression fail; the corrected order passed.
- **PASS:** Release build via `./script/build_and_run.sh`, independent backend compilation, Swift format lint, and `git diff --check`.
- **PASS:** `./script/live_audio_test.sh --change-audio` completed on both the DAC and built-in speakers at 22:46:42. DAC source→output rates: 44.1→44.1, 48→48, 88.2→44.1, 96→96, 176.4→44.1, and 192→192 kHz. Each checked full formats and repeated-reconcile write suppression. Original-snapshot restoration and preservation of external takeover through stop passed on both devices. The final cleanup verified all original snapshots and the default output. Unsupported-source cases were explicitly skipped because all six candidates had usable targets.
- **PASS:** real sequential playback through the corrected Release follower, with independent full-format readback. Each track kept 24-bit signed packed physical PCM (flags 12, 6 bytes per frame/packet) and 32-bit float virtual PCM (flags 9, 8 bytes per frame/packet), stereo with one frame per packet. No yield or duplicate alignment write occurred during this sequence.

| Track / item | Source | Write start → full verification | Transaction |
| --- | --- | --- | --- |
| 虹色の光りの中で / `I/BPV.01` | 16-bit / 44.1 kHz | 22:49:39.694 → 22:49:40.545 (851 ms) | `3722923B-976A-46EA-9745-14261019F32F` |
| World's End Loneliness (Full Ver.) / `I/KPK.01` | 24-bit / 48 kHz | 22:49:46.213 → 22:49:47.055 (842 ms) | `9DFC5B4C-AE0F-438B-809D-8914A2D2C85F` |
| Abstruse Dilemma / `I/OGE.01` | 24-bit / 44.1 kHz | 22:50:04.869 → 22:50:05.681 (812 ms) | `783DEBA7-41B6-472F-994F-CFF2EDAFD993` |

- **PASS:** normal Music quit was observed at 22:50:17.931. Restoration transaction `06B77302-2146-4296-ACD6-0ED43EB78A3E` ran from 22:50:17.932 to 22:50:18.840 (908 ms). Independent readback confirmed the full original 48 kHz/16-bit physical and 32-bit float virtual state. This time the production controller restored it without a recovery probe.

The earlier sleep/wake and physical USB replug records remain historical; those interactions were not repeated for this write-order fix. They do not imply automatic recovery within the same Music session. Other DACs, repeated lifecycle cycles, and long unattended operation remain outside this validation.

Cleanup returned default output to speakers and verified both original device formats at 22:51:26.910. The temporary follower exited normally; the observer and scratch files were removed. Music was reopened stopped, and the original installed helper was restarted under launchd (PID 76579, parent 1). Its SHA-256 remained `9e5738405cc0a20ea51c23c491d76d3f8620403bc03eac73ea15e4e0b2d14c64`: this fix is in the working tree and Release build, not the installed executable. No commit or push was made.
