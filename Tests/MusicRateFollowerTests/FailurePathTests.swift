import CoreAudio
import XCTest

@testable import MusicRateFollower

private final class FakeAudio {
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
    var writes: [Double] = []
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
            self.writes.append(next.rate)
            self.deviceListenersAtWrite.append(self.callbacks.filter { $0.0 != 1 }.count)
            // Cap write attempts so a retry regression cannot loop indefinitely.
            guard self.writes.count < 8 else { throw AudioFailure.changed }
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
        let f = FakeAudio()
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
        let f = FakeAudio()
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
        let f = FakeAudio()
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
        let f = FakeAudio()
        f.failingSelector = kAudioHardwarePropertyDevices
        let c = f.controller()
        c.reconcile()
        pump()
        XCTAssertTrue(f.writes.isEmpty)
        XCTAssertTrue(f.callbacks.isEmpty)
        stop(c)
    }
    func testTransientFirstReadCannotBypassRequiredDeviceListeners() {
        let f = FakeAudio()
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
        let healthy = FakeAudio()
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
        let f = FakeAudio()
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
            f.writes.append(next.rate)
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
        let f = FakeAudio()
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
        let messages = [
            "<<<< AVPlayer >>>> -[AVPlayer _setCurrentItem:]: <P/JK|0x123> currentItem KVO: updating current item from (null) to I/A",
            "<<<< FigStreamPlayer >>>> fpfs_SetRateOnTrack: [0x123|P/JK] <0x456|I/A>: rate 1.000000 set on track 1 (audio)",
            "<<<< FigStreamPlayer >>>> fpfs_ReportAudioPlaybackThroughFigLog: [QE Critical][0x123|P/JK]: <0x456|I/A>: [AudioFormat qlac is  decodable] [AudioChannels 2] [Spatialization no] [StereoSpatialization no] [Rendition Lossless] [SampleRate 96000] [BitDepth 24] [Immersive rendering no]",
        ]
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
        e.finish(success: true, pid: 123)
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
        e.finish(success: true, pid: 123)
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
        e.finish(success: true, pid: 123)
        XCTAssertEqual(e.target?.rate, 96000)
        e.receive(["eventType": "lossEvent"], pid: 123)
        for r in records(100) { e.receive(r, pid: 123) }
        XCTAssertNil(e.target)
        XCTAssertGreaterThanOrEqual(e.lastStamp, 200)
    }
}
