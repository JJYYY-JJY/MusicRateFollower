import CoreAudio
import XCTest

@testable import MusicRateFollower

final class FakeAudio {
    static func device(_ id: UInt32 = 78, _ uid: String = "speaker") -> DeviceState {
        let f = AudioStreamBasicDescription(
            mSampleRate: 44100, mFormatID: kAudioFormatLinearPCM, mFormatFlags: 9,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2,
            mBitsPerChannel: 32, mReserved: 0)
        return DeviceState(
            id: id, uid: uid, rate: 44100,
            streams: [StreamState(id: id + 1, physical: f, virtual: f)])
    }
    var states: [UInt32: DeviceState] = [78: device(), 85: device(85, "headphones")]
    var selected: UInt32 = 78
    var failingSelector: UInt32?
    var partialFailure = true
    var holdPartialWithoutError = false
    var writtenStates: [DeviceState] = []
    var writes: [Double] { writtenStates.map(\.rate) }
    let writeLimit: Int
    init(writeLimit: Int) { self.writeLimit = writeLimit }
    var callbacks: [(UInt32, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    var added: [UInt32] = []
    var removed: [UInt32] = []
    var statuses: [String] = []
    var reads = 0
    var failingReads: Set<Int> = []
    var deviceListenersAtWrite: [Int] = []
    func access() -> AudioAccess {
        var a = AudioAccess()
        a.defaultDevice = { self.selected }
        a.read = { id in
            self.reads += 1
            if self.failingReads.contains(self.reads) { throw AudioFailure.status(-1) }
            return self.states[id]!
        }
        a.target = { current, rate in
            var next = current
            next.rate = rate
            for i in next.streams.indices {
                next.streams[i].physical.mSampleRate = rate
                next.streams[i].virtual.mSampleRate = rate
            }
            return next
        }
        a.write = { next, before in
            self.writtenStates.append(next)
            self.deviceListenersAtWrite.append(self.callbacks.filter { $0.0 != 1 }.count)
            // Cap write attempts so a retry regression cannot loop indefinitely.
            guard self.writes.count <= self.writeLimit else { throw AudioFailure.changed }
            self.states[next.id]!.streams[0].physical = next.streams[0].physical
            self.notify()
            if next.rate != 44100 {
                if self.partialFailure { throw AudioFailure.status(-1) }
                if self.holdPartialWithoutError { return }
            }
            self.states[next.id] = next
        }
        a.addListener = { id, address, callback in
            if self.failingSelector == address.mSelector { return -1 }
            self.callbacks.append((id, address, callback))
            self.added.append(address.mSelector)
            return noErr
        }
        a.removeListener = { id, address, _ in
            self.callbacks.removeAll {
                $0.0 == id && $0.1.mSelector == address.mSelector && $0.1.mScope == address.mScope
            }
            self.removed.append(address.mSelector)
            return noErr
        }
        return a
    }
    func notify() {
        let callbacks = self.callbacks
        DispatchQueue.main.async {
            for (_, var address, callback) in callbacks {
                withUnsafePointer(to: &address) { callback(1, $0) }
            }
        }
    }
    func controller() -> AudioControl {
        let c = AudioControl(access: access())
        c.onStatus = { self.statuses.append($0) }
        c.start()
        c.source = SourceFormat(rate: 48000, bits: 24, item: "same-track")
        return c
    }
}

final class FailurePathTests: XCTestCase {
    func testProductionWritesPreservePhysicalFormatAfterDriverRenegotiation() throws {
        var original = FakeAudio.device()
        original.rate = 48000
        original.streams[0].physical.mSampleRate = 48000
        original.streams[0].physical.mFormatFlags =
            kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
        original.streams[0].physical.mBitsPerChannel = 16
        original.streams[0].physical.mBytesPerFrame = 4
        original.streams[0].physical.mBytesPerPacket = 4
        original.streams[0].virtual.mSampleRate = 48000
        var target = original
        target.rate = 44100
        target.streams[0].physical.mSampleRate = 44100
        target.streams[0].physical.mBitsPerChannel = 24
        target.streams[0].physical.mBytesPerFrame = 6
        target.streams[0].physical.mBytesPerPacket = 6
        target.streams[0].virtual.mSampleRate = 44100
        // Also cover a virtual-only change: physical initially matches the
        // target but the virtual setter renegotiates it to 32-bit anyway.
        var virtualOnly = target
        virtualOnly.streams[0].virtual.mSampleRate = 48000
        for (before, after) in [(original, target), (target, original), (virtualOnly, target)] {
            var actual = before
            var pending: [() -> Void] = []
            func renegotiate(_ rate: Double) {
                actual.rate = rate
                actual.streams[0].virtual.mSampleRate = rate
                actual.streams[0].physical.mSampleRate = rate
                actual.streams[0].physical.mBitsPerChannel = 32
                actual.streams[0].physical.mBytesPerFrame = 8
                actual.streams[0].physical.mBytesPerPacket = 8
            }
            try after.writeChanges(
                from: before, readUID: { _ in actual.uid }, readRate: { _ in actual.rate },
                readVirtual: { _ in actual.streams[0].virtual },
                writeRate: { _, rate in
                    pending.append { renegotiate(rate) }
                },
                writeFormat: { _, selector, format in
                    pending.append {
                        if selector == kAudioStreamPropertyVirtualFormat {
                            renegotiate(format.mSampleRate)
                            actual.streams[0].virtual = format
                        } else {
                            actual.streams[0].physical = format
                        }
                    }
                })
            XCTAssertEqual(actual, before, "setter return does not establish completion")
            for complete in pending { complete() }
            XCTAssertEqual(actual, after, "full format must survive rate/virtual renegotiation")
        }
    }

    private func pump(_ seconds: Double = 0.05) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
    private func stop(_ c: AudioControl) {
        var done = false
        c.stop { done = true }
        pump()
        XCTAssertTrue(done)
    }

    func testPartialWriteRollbackDoesNotReacquireFromOwnNotifications() {
        let f = FakeAudio(writeLimit: 8)
        let c = f.controller()
        c.reconcile()
        pump()
        for _ in 0..<20 {
            f.notify()
            c.reconcile()
        }
        pump()
        XCTAssertEqual(f.writes, [48000, 44100])
        XCTAssertEqual(f.states[78], FakeAudio.device())
        XCTAssertTrue(f.statuses.contains { $0.contains("yielded") })
        c.source = SourceFormat(rate: 96000, bits: 24, item: "another-track")
        c.reconcile()
        pump()
        XCTAssertEqual(f.writes, [48000, 44100], "changing tracks must not bypass a fault yield")
        stop(c)
        f.partialFailure = false
        c.start()
        c.source = SourceFormat(rate: 48000, bits: 24, item: "new-session")
        c.reconcile()
        pump()
        XCTAssertEqual(f.states[78]?.rate, 48000)
        stop(c)
    }
    func testVerificationTimeoutRollbackAlsoYields() {
        let f = FakeAudio(writeLimit: 8)
        f.partialFailure = false
        f.holdPartialWithoutError = true
        let c = f.controller()
        c.reconcile()
        pump(1.15)
        f.notify()
        c.reconcile()
        pump()
        XCTAssertEqual(f.writes, [48000, 44100])
        XCTAssertEqual(f.states[78], FakeAudio.device())
        stop(c)
    }
    func testCriticalDeviceListenerFailurePreventsWritesAndCleansPartialRegistration() {
        let f = FakeAudio(writeLimit: 8)
        f.partialFailure = false
        f.failingSelector = kAudioStreamPropertyVirtualFormat
        let c = f.controller()
        c.reconcile()
        pump()
        XCTAssertTrue(f.writes.isEmpty)
        XCTAssertFalse(f.callbacks.contains { $0.0 != 1 })
        XCTAssertTrue(f.statuses.contains { $0.contains("listener") })
        f.failingSelector = nil
        c.reconcile()
        pump()
        XCTAssertTrue(f.writes.isEmpty)
        stop(c)
    }
    func testSystemListenerFailurePreventsWrites() {
        let f = FakeAudio(writeLimit: 8)
        f.failingSelector = kAudioHardwarePropertyDevices
        let c = f.controller()
        c.reconcile()
        pump()
        XCTAssertTrue(f.writes.isEmpty)
        XCTAssertTrue(f.callbacks.isEmpty)
        stop(c)
    }
    func testTransientFirstReadCannotBypassRequiredDeviceListeners() {
        let f = FakeAudio(writeLimit: 8)
        f.partialFailure = false
        f.failingReads = [1]
        f.failingSelector = kAudioStreamPropertyVirtualFormat
        let c = f.controller()
        c.reconcile()
        XCTAssertTrue(
            f.writes.isEmpty,
            "the second read must not authorize a write without an observation baseline")
        pump()
        c.reconcile()
        pump()
        XCTAssertTrue(f.writes.isEmpty, "listener failure must prevent every write")
        XCTAssertTrue(f.deviceListenersAtWrite.isEmpty)
        XCTAssertTrue(f.statuses.contains { $0.contains("listener-registration-failed") })
        stop(c)
        XCTAssertEqual(f.states[78], FakeAudio.device())

        // A transient read failure may recover when all required listeners succeed.
        let healthy = FakeAudio(writeLimit: 8)
        healthy.partialFailure = false
        healthy.failingReads = [1]
        let retry = healthy.controller()
        retry.reconcile()
        XCTAssertTrue(healthy.writes.isEmpty)
        retry.reconcile()
        pump()
        XCTAssertEqual(healthy.states[78]?.rate, 48000)
        XCTAssertTrue(healthy.deviceListenersAtWrite.allSatisfy { $0 >= 4 })
        stop(retry)
        XCTAssertEqual(healthy.states[78], FakeAudio.device())
    }
    func testOldTimeoutCannotAbandonNewRestoreTransactionDuringStop() {
        let f = FakeAudio(writeLimit: 8)
        let restoreStarted = expectation(description: "restore transaction started")
        var a = f.access()
        var requested: DeviceState?
        var completeOnNextRead = false
        a.read = { id in
            if completeOnNextRead, let next = requested {
                f.states[id] = next
                completeOnNextRead = false
            }
            return f.states[id]!
        }
        a.write = { next, _ in
            f.writtenStates.append(next)
            f.states[next.id]!.streams[0].physical = next.streams[0].physical
            if next.rate == 48000 { requested = next } else { restoreStarted.fulfill() }
            // Completion is deliberately delayed; no notification resolves it early.
        }
        let c = AudioControl(access: a)
        c.onStatus = { f.statuses.append($0) }
        c.start()
        c.source = SourceFormat(rate: 48000, bits: 24, item: "pending-on-stop")
        c.reconcile()
        var completed: DeviceState?
        c.stop { completed = f.states[78] }
        XCTAssertNil(completed)
        // The original timer observes the initial write completing. check() then
        // starts a new, still-partial restore with its own token and timeout.
        completeOnNextRead = true
        wait(for: [restoreStarted], timeout: 3)
        pump()
        XCTAssertEqual(f.writes, [48000, 44100])
        XCTAssertNil(completed, "old timeout must not finish stop during the new restore")
        XCTAssertEqual(f.states[78]?.rate, 48000)
        XCTAssertEqual(f.states[78]?.streams[0].physical.mSampleRate, 44100)
        XCTAssertEqual(f.states[78]?.streams[0].virtual.mSampleRate, 48000)
        XCTAssertFalse(f.statuses.contains { $0.hasPrefix("yielded") })
        f.states[78] = FakeAudio.device()
        f.notify()
        pump()
        XCTAssertEqual(
            completed, FakeAudio.device(), "stop completes only after the full restore is confirmed"
        )
        XCTAssertTrue(f.statuses.contains { $0.hasPrefix("restored") })
    }
    func testNormalDeviceReturnAllowsReacquisitionAndExternalChangeStillYields() {
        let f = FakeAudio(writeLimit: 8)
        f.partialFailure = false
        let c = f.controller()
        c.reconcile()
        pump()
        f.selected = 85
        f.notify()
        pump()
        XCTAssertEqual(f.states[78], FakeAudio.device())
        XCTAssertEqual(f.states[85]?.rate, 48000)
        f.selected = 78
        f.notify()
        pump()
        XCTAssertEqual(f.states[78]?.rate, 48000)
        XCTAssertEqual(f.writes.filter { $0 == 48000 }.count, 3)
        f.states[78] = FakeAudio.device()
        f.notify()
        pump()
        let count = f.writes.count
        c.reconcile()
        pump()
        XCTAssertEqual(f.writes.count, count)
        stop(c)
        XCTAssertEqual(f.states[78], FakeAudio.device())
        XCTAssertEqual(f.states[85], FakeAudio.device(85, "headphones"))
    }

    private func records(_ start: UInt64) -> [[String: Any]] {
        let helper = RegressionTests()
        let messages = [helper.current("I/A"), helper.rate("I/A", 1), helper.report("I/A", 96000)]
        return messages.enumerated().map { i, m in
            [
                "processID": 123,
                "processImagePath": "/System/Applications/Music.app/Contents/MacOS/Music",
                "subsystem": "com.apple.coremedia", "eventMessage": m,
                "machTimestamp": start + UInt64(i),
            ]
        }
    }
    func testLossCancelsHistoryAndOldHistoryCannotReauthorize() {
        let e = PlaybackEvidence(now: { 200 })
        e.begin()
        var cancelled = false
        e.onCancelHistory = { cancelled = true }
        e.receive(["eventType": "lossEvent", "machTimestamp": 200], pid: 123)
        for r in records(100) { e.receive(r, pid: 123, fromHistory: true) }
        e.finish(success: true)
        XCTAssertTrue(cancelled)
        XCTAssertNil(e.target)
        XCTAssertGreaterThanOrEqual(e.lastStamp, 200)
        // Even a cancelled history callback with a later timestamp is not live evidence.
        for r in records(250) { e.receive(r, pid: 123, fromHistory: true) }
        XCTAssertNil(e.target)
        for r in records(201) { e.receive(r, pid: 123) }
        XCTAssertEqual(e.target?.rate, 96000)
    }
    func testSleepAndWakeInvalidateHistoryAndQueuedLiveRecords() {
        var clock: UInt64 = 200
        let e = PlaybackEvidence(now: { clock })
        e.begin()
        var cancellations = 0
        e.onCancelHistory = { cancellations += 1 }
        for r in records(100) { e.receive(r, pid: 123, fromHistory: true) }
        e.invalidate(suspended: true)
        XCTAssertEqual(cancellations, 1)
        e.finish(success: true)
        for r in records(210) { e.receive(r, pid: 123) }
        XCTAssertNil(e.target)
        clock = 300
        e.invalidate(suspended: false)
        for r in records(220) { e.receive(r, pid: 123) }
        for r in records(310) { e.receive(r, pid: 123, fromHistory: true) }
        XCTAssertNil(e.target)
        XCTAssertGreaterThanOrEqual(e.lastStamp, 300)
        for r in records(301) { e.receive(r, pid: 123) }
        XCTAssertEqual(e.target?.rate, 96000)
    }
    func testNormalBootstrapAndLossWithoutTimestamp() {
        let e = PlaybackEvidence(now: { 200 })
        e.begin()
        for r in records(100).reversed() { e.receive(r, pid: 123, fromHistory: true) }
        e.finish(success: true)
        XCTAssertEqual(e.target?.rate, 96000)
        e.receive(["eventType": "lossEvent"], pid: 123)
        for r in records(100) { e.receive(r, pid: 123) }
        XCTAssertNil(e.target)
        XCTAssertGreaterThanOrEqual(e.lastStamp, 200)
    }

    func testUntrustworthyCriticalRecordsRevokeTargetAndRequireFreshEvidence() {
        let stop =
            "<<<< FigStreamPlayer >>>> fpfs_StopPlayingItem: [0x123|P/JK] <0x456|I/A>: Stopping, err=(null)"
        var bad = records(103)[0]
        bad["eventMessage"] = stop
        let invalidStamps: [Any?] = [
            nil, -1, 1.5, true, "103", Double.nan, NSDecimalNumber(string: "18446744073709551616"),
            102, 101,
        ]
        for stamp in invalidStamps {
            let e = PlaybackEvidence(now: { 200 })
            e.begin()
            for r in records(100) { e.receive(r, pid: 123) }
            e.finish(success: true)
            XCTAssertNotNil(e.target)
            bad["machTimestamp"] = stamp
            e.receive(bad, pid: 123)
            XCTAssertNil(e.target, "invalid stamp: \(String(describing: stamp))")
            for r in records(150) { e.receive(r, pid: 123) }
            XCTAssertNil(e.target)
            for r in records(201) { e.receive(r, pid: 123) }
            XCTAssertEqual(e.target?.rate, 96000, "fresh evidence must recover")
        }
    }

    func testMissingTimestampDuringBootstrapCancelsHistory() {
        let e = PlaybackEvidence(now: { 200 })
        e.begin()
        var cancelled = false
        e.onCancelHistory = { cancelled = true }
        for r in records(100) { e.receive(r, pid: 123, fromHistory: true) }
        var change = records(103)[0]
        change["machTimestamp"] = nil
        change["eventMessage"] = (change["eventMessage"] as! String).replacingOccurrences(
            of: "I/A", with: "I/B")
        e.receive(change, pid: 123, fromHistory: true)
        e.finish(success: true)
        XCTAssertTrue(cancelled)
        XCTAssertNil(e.target)
    }

    func testUnrelatedRecordsDoNotAdvanceEvidenceClock() {
        let e = PlaybackEvidence(now: { 200 })
        e.begin()
        e.finish(success: true)
        var unrelated = records(1000)[0]
        unrelated["processID"] = 321
        e.receive(unrelated, pid: 123)
        unrelated["processID"] = 123
        unrelated["eventMessage"] = "output sampleRate: 96000"
        e.receive(unrelated, pid: 123)
        for r in records(100) { e.receive(r, pid: 123) }
        XCTAssertEqual(e.target?.rate, 96000)
        XCTAssertEqual(e.lastStamp, 102)
    }
    func testInvalidEvidenceCannotConfigureNewOutput() {
        let e = PlaybackEvidence(now: { 200 })
        e.begin()
        for r in records(100) { e.receive(r, pid: 123) }
        e.finish(success: true)
        let f = FakeAudio(writeLimit: 4)
        f.partialFailure = false
        let c = f.controller()
        c.source = e.target
        c.reconcile()
        pump()
        XCTAssertEqual(f.states[78]?.rate, 96000)
        var preload = records(110)[2]
        preload["eventMessage"] = (preload["eventMessage"] as! String).replacingOccurrences(
            of: "I/A", with: "I/PRELOAD")
        e.receive(preload, pid: 123)
        var stoppedRecord = records(105)[1]
        stoppedRecord["eventMessage"] = RegressionTests().rate("I/A", 0)
        e.receive(stoppedRecord, pid: 123)  // Late stop after a newer preload.
        XCTAssertNil(e.target)
        c.source = e.target
        f.selected = 85
        f.notify()
        pump()
        XCTAssertEqual(
            f.writtenStates,
            [
                {
                    var s = FakeAudio.device()
                    s.rate = 96000
                    s.streams[0].physical.mSampleRate = 96000
                    s.streams[0].virtual.mSampleRate = 96000
                    return s
                }(),
                FakeAudio.device(),
            ], "only A's original output is restored; the new output must not be configured")
        XCTAssertEqual(f.states[85], FakeAudio.device(85, "headphones"))
        for var r in records(201) {
            r["eventMessage"] = (r["eventMessage"] as! String).replacingOccurrences(
                of: "I/A", with: "I/B")
            e.receive(r, pid: 123)
            c.source = e.target
            c.reconcile()
        }
        pump()
        XCTAssertEqual(c.source?.item, "I/B")
        XCTAssertEqual(f.writtenStates.map(\.id), [78, 78, 85])
        XCTAssertEqual(f.states[85]?.rate, 96000)
        stop(c)
        XCTAssertEqual(f.writtenStates.last, FakeAudio.device(85, "headphones"))
    }

    func testMalformedCriticalMessagesAndTimestampCollisionsInvalidateReplay() {
        let helper = RegressionTests()
        let malformed = [
            helper.current("I/B").replacingOccurrences(of: "<P/JK|", with: "<unknown|"),
            helper.current("unrecognized-item"),
            helper.rate("I/A", 0).replacingOccurrences(of: "0.000000", with: "nan"),
            helper.report("I/A").replacingOccurrences(
                of: "[BitDepth 24]", with: "[BitDepth unknown]"),
        ]
        for history in [false, true] {
            for message in malformed + [helper.current("I/B")] {
                let e = PlaybackEvidence(now: { 200 })
                e.begin()
                for r in records(100) { e.receive(r, pid: 123, fromHistory: history) }
                if !history { e.finish(success: true) }
                var bad = records(message == helper.current("I/B") ? 102 : 103)[0]
                bad["eventMessage"] = message
                e.receive(bad, pid: 123, fromHistory: history)
                if history { XCTAssertFalse(e.finish(success: true)) }
                XCTAssertNil(e.target)
                XCTAssertEqual(e.lastStamp, 200)
                for r in records(201) { e.receive(r, pid: 123) }
                XCTAssertEqual(e.target?.rate, 96000)
            }
        }
    }

    func testExactDuplicateRetentionIsBoundedAndInvalidationClearsIt() {
        let e = PlaybackEvidence(now: { 10000 })
        e.begin()
        for r in records(100) { e.receive(r, pid: 123) }
        e.finish(success: true)
        for r in records(100) { e.receive(r, pid: 123) }
        XCTAssertEqual(e.target?.rate, 96000)
        for stamp in 103...4198 {
            var r = records(UInt64(stamp))[2]
            r["eventMessage"] = RegressionTests().report("I/PRELOAD")
            e.receive(r, pid: 123)
        }
        XCTAssertEqual(e.target?.rate, 96000)
        e.receive(records(100)[0], pid: 123)
        XCTAssertNil(e.target, "evicted records cannot be proven duplicates")
        XCTAssertEqual(e.lastStamp, 10000)
        e.receive(["eventType": "lossEvent", "machTimestamp": 9999], pid: 123)
        XCTAssertEqual(e.lastStamp, 10000, "queued loss before the boundary is inert")
        for r in records(10001) { e.receive(r, pid: 123) }
        XCTAssertEqual(e.target?.rate, 96000)
    }

}
