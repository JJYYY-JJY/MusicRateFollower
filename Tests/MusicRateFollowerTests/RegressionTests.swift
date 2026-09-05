import CoreAudio
import XCTest

@testable import MusicRateFollower

final class RegressionTests: XCTestCase {
    func testIntegerDivisionSelection() {
        let fixed: [ClosedRange<Double>] = [44100...44100, 48000...48000]
        XCTAssertEqual(chooseSampleRate(source: 192000, ranges: fixed), 48000)
        XCTAssertEqual(chooseSampleRate(source: 176400, ranges: fixed), 44100)
        XCTAssertEqual(chooseSampleRate(source: 48000, ranges: fixed), 48000)
        XCTAssertEqual(chooseSampleRate(source: 192000, ranges: fixed + [96000...96000]), 96000)
        XCTAssertEqual(
            chooseSampleRate(source: 192000, ranges: [64000...64000]), 64000,
            "division need not be a power of two")
        XCTAssertEqual(chooseSampleRate(source: 176400, ranges: [48000...96000]), 88200)
        XCTAssertNil(chooseSampleRate(source: 44100, ranges: [48000...48000]))
        XCTAssertNil(chooseSampleRate(source: .nan, ranges: fixed))
        XCTAssertNil(chooseSampleRate(source: .infinity, ranges: fixed))
        XCTAssertNil(chooseSampleRate(source: 0, ranges: fixed))
        XCTAssertNil(chooseSampleRate(source: 192000, ranges: []))
        XCTAssertEqual(
            Set(intersectRates([40000...96000], [44100...44100, 48000...48000])),
            Set([44100.0...44100.0, 48000.0...48000.0]))
        XCTAssertTrue(
            rateRanges([
                AudioValueRange(mMinimum: 0, mMaximum: 48000),
                AudioValueRange(mMinimum: 48000, mMaximum: .infinity),
            ]).isEmpty)
    }
    func testIntervalAlgorithmAgainstBruteForce() {
        for source in stride(from: 1000.0, through: 192000, by: 1000) {
            for upper in stride(from: 2000.0, through: 100000, by: 7000) {
                let range = (upper / 2)...upper
                let expected = (1...512).map { source / Double($0) }.first(where: range.contains)
                XCTAssertEqual(chooseSampleRate(source: source, ranges: [range]), expected)
            }
        }
        XCTAssertTrue(
            alignmentStatus(source: 192000, output: 96000, verified: true).hasPrefix(
                "downsampled-verified"))
    }
    func testCapturedMacOS27PlaybackEvidence() throws {
        let path = Bundle.module.url(
            forResource: "stream", withExtension: "ndjson", subdirectory: "Fixtures")!
        let text = try String(contentsOf: path, encoding: .utf8)
        let records = try text.split(separator: "\n").map {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
        }
        // Reviewed against the raw fixture. LKR never receives positive-rate evidence;
        // NX is silent artwork. Neither may authorize a target.
        let intervals: [(ClosedRange<Int>, String, Double, Int)] = [
            (21...21, "I/IWA.01", 44100, 16), (27...32, "I/IRX.01", 44100, 16),
            (37...141, "I/LXL.01", 192000, 24), (235...239, "I/GAB.01", 48000, 24),
            (240...312, "I/GAB.01", 192000, 24), (317...333, "I/ZDD.01", 48000, 24),
            (334...343, "I/ZDD.01", 192000, 24), (349...349, "I/XMF.01", 48000, 24),
            (350...350, "I/XMF.01", 96000, 24), (352...352, "I/XMF.01", 96000, 24),
            (354...355, "I/XMF.01", 96000, 24), (357...357, "I/XMF.01", 96000, 24),
            (359...359, "I/XMF.01", 96000, 24),
        ]
        func expected(_ line: Int) -> SourceFormat? {
            intervals.first { $0.0.contains(line) }.map {
                SourceFormat(rate: $0.2, bits: $0.3, item: $0.1)
            }
        }
        let e = PlaybackEvidence()
        e.begin()
        e.finish(success: true)
        let f = FakeAudio(writeLimit: 8)
        f.partialFailure = false
        let c = f.controller()
        for (index, record) in records.enumerated() {
            e.receive(record, pid: 80157)
            XCTAssertEqual(e.target, expected(index + 1), "fixture line \(index + 1)")
            c.source = e.target
            c.reconcile()
            RunLoop.main.run(until: Date().addingTimeInterval(0.001))
            let count = f.writes.count
            e.receive(record, pid: 80157)  // Exact replay must not change state or write again.
            c.source = e.target
            c.reconcile()
            XCTAssertEqual(f.writes.count, count, "duplicate at line \(index + 1)")
        }
        XCTAssertEqual(f.writes, [192000, 48000, 192000, 48000, 192000, 48000, 96000])
        XCTAssertTrue(
            f.writtenStates.allSatisfy { state in
                state.id == 78
                    && state.streams.allSatisfy {
                        $0.physical.mSampleRate == state.rate
                            && $0.virtual.mSampleRate == state.rate
                    }
            })
        var stopped = false
        c.stop { stopped = true }
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        XCTAssertTrue(stopped)
        XCTAssertEqual(f.writtenStates.last, FakeAudio.device(), "final write is restoration")

        // Reverse history, overlap it with live records, then continue live playback.
        for split in [21, 37, 145, 189, 240, 350, 360] {
            let replay = PlaybackEvidence()
            replay.begin()
            for record in records.prefix(split).reversed() {
                replay.receive(record, pid: 80157, fromHistory: true)
                replay.receive(record, pid: 80157)
                XCTAssertNil(replay.target)
            }
            replay.finish(success: true)
            XCTAssertEqual(replay.target, expected(split), "bootstrap through line \(split)")
            for (index, record) in records.enumerated() {
                replay.receive(record, pid: 80157)
                XCTAssertEqual(
                    replay.target, expected(max(split, index + 1)), "replay line \(index + 1)")
            }
        }
    }

    func testProductionTargetUsesAllStreamCapabilities() throws {
        let state = FakeAudio.device()
        let rates: [Double] = [44100, 48000, 88200, 96000, 176400]
        func ranges(_ values: [Double]) -> [AudioValueRange] {
            values.map { AudioValueRange(mMinimum: $0, mMaximum: $0) }
        }
        func formats(_ values: [Double], _ format: AudioStreamBasicDescription)
            -> [AudioStreamRangedDescription]
        {
            ranges(values).map {
                AudioStreamRangedDescription(mFormat: format, mSampleRateRange: $0)
            }
        }
        let full = try state.target(
            192000, nominalRates: { _ in ranges(rates) },
            streamFormats: { _, _ in
                formats(rates, state.streams[0].physical)
            })
        XCTAssertEqual(full.rate, 96000, "highest integer division, not 176400 maximum")
        XCTAssertEqual(full.streams[0].physical.mSampleRate, 96000)
        XCTAssertEqual(full.streams[0].virtual.mSampleRate, 96000)
        var multi = state
        multi.streams.append(
            StreamState(
                id: 90, physical: state.streams[0].physical, virtual: state.streams[0].virtual))
        let limited = try multi.target(
            192000, nominalRates: { _ in ranges(rates) },
            streamFormats: { id, selector in
                formats(
                    id == 90 && selector == kAudioStreamPropertyAvailableVirtualFormats
                        ? [48000] : rates,
                    state.streams[0].physical)
            })
        XCTAssertEqual(limited.rate, 48000)
        for selector in [
            kAudioStreamPropertyAvailablePhysicalFormats,
            kAudioStreamPropertyAvailableVirtualFormats,
        ] {
            XCTAssertThrowsError(
                try multi.target(
                    192000, nominalRates: { _ in ranges(rates) },
                    streamFormats: { id, property in
                        formats(
                            id == 90 && property == selector ? [44100] : [48000],
                            state.streams[0].physical)
                    }))
        }
        XCTAssertThrowsError(
            try state.target(
                192000, nominalRates: { _ in ranges([44100]) },
                streamFormats: { _, _ in
                    formats([48000], state.streams[0].physical)
                }))
        var inadequate = state.streams[0].physical
        inadequate.mFormatFlags = kAudioFormatFlagIsSignedInteger
        inadequate.mBitsPerChannel = 16
        XCTAssertThrowsError(
            try state.target(
                192000, nominalRates: { _ in ranges(rates) },
                streamFormats: { _, _ in
                    formats(rates, inadequate)
                }))
    }
    func event(_ m: String, pid: Int = 123) -> [String: Any] {
        [
            "processID": pid,
            "processImagePath": "/System/Applications/Music.app/Contents/MacOS/Music",
            "subsystem": "com.apple.coremedia", "eventMessage": m,
        ]
    }
    func current(_ item: String) -> String {
        "<<<< AVPlayer >>>> -[AVPlayer _setCurrentItem:]: <P/JK|0x123> currentItem KVO: updating current item from (null) to \(item)"
    }
    func rate(_ item: String, _ rate: Int) -> String {
        "<<<< FigStreamPlayer >>>> fpfs_SetRateOnTrack: [0x123|P/JK] <0x456|\(item)>: rate \(rate).000000 set on track 1 (audio)"
    }
    func report(_ item: String, _ rate: Int = 44100) -> String {
        "<<<< FigStreamPlayer >>>> fpfs_ReportAudioPlaybackThroughFigLog: [QE Critical][0x123|P/JK]: <0x456|\(item)>: [AudioFormat qlac is  decodable] [AudioChannels 2] [Spatialization Eligible yes] [Client permits multi: no, stereo: no] [Spatialization no] [StereoSpatialization no] [Rendition Lossless] [SampleRate \(rate)] [BitDepth 24] [Immersive rendering no]"
    }
    func testCurrentItemAndPositiveAudioRateAreRequired() {
        var d = Detection()
        d.consume(event(report("I/A")), pid: 123)
        XCTAssertNil(d.target)
        d.consume(event(current("I/A")), pid: 123)
        XCTAssertNil(d.target)
        d.consume(event(rate("I/A", 1)), pid: 123)
        XCTAssertEqual(d.target?.rate, 44100)
        d.consume(event(report("I/PRELOAD", 192000)), pid: 123)
        XCTAssertEqual(d.target?.rate, 44100)
        d.consume(event(current("I/B")), pid: 123)
        XCTAssertNil(d.target)
        d.consume(event(rate("I/B", 1)), pid: 123)
        d.consume(event(report("I/B", 96000)), pid: 123)
        XCTAssertEqual(d.target?.rate, 96000)
        d.consume(event(rate("I/B", 0)), pid: 123)
        XCTAssertNil(d.target)
        d.consume(event(rate("I/B", 1)), pid: 123)
        XCTAssertEqual(d.target?.rate, 96000)
        d.paused = true
        XCTAssertNil(d.target)
    }
    func testRejectUnknownValuesOtherProcessesLossyAndSpatial() {
        var d = Detection()
        d.consume(event(current("I/A")), pid: 123)
        d.consume(event(rate("I/A", 1)), pid: 123)
        for m in [
            "output sampleRate: 96000", "48000 frames duration: 1", "{\"sampleRate\":192000}",
        ] {
            d.consume(event(m), pid: 123)
            XCTAssertNil(d.target)
        }
        d.consume(event(report("I/A"), pid: 321), pid: 123)
        XCTAssertNil(d.target)
        d.consume(event(report("I/A")), pid: 123)
        XCTAssertNotNil(d.target)
        d.consume(event(report("I/A").replacingOccurrences(of: "qlac", with: "qaac")), pid: 123)
        XCTAssertNil(d.target)
        d.consume(
            event(
                report("I/A").replacingOccurrences(
                    of: "[Spatialization no]", with: "[Spatialization yes]")), pid: 123)
        XCTAssertNil(d.target)
    }
    func testStopAndOutOfOrderCurrentItem() {
        var d = Detection()
        d.consume(event(rate("I/A", 1)), pid: 123)
        d.consume(event(current("I/A")), pid: 123)
        d.consume(event(report("I/A")), pid: 123)
        XCTAssertNotNil(d.target)
        d.consume(
            event(
                "<<<< FigStreamPlayer >>>> fpfs_StopPlayingItem: [0x123|P/JK] <0x456|I/A>: Stopping, err=(null)"
            ), pid: 123)
        XCTAssertNil(d.target)
    }
    func testGaplessTransitionWithoutSetRateOnTrackAndVideoPlayer() {
        var d = Detection()
        let change =
            "<<<< FigStreamPlayer >>>> fpfs_SetRateWithOptionsAndAnchorTime: [0x123|P/JK] <0x456|I/NEXT>: called at 0.0094223, rate = 1.000, fadeDuration = nan, immediately: no, reason: CurrentItemChanged"
        d.consume(event(change), pid: 123)
        d.consume(event(report("I/NEXT", 96000)), pid: 123)
        XCTAssertNil(d.target, "not current yet")
        d.consume(event(current("I/NEXT")), pid: 123)
        XCTAssertEqual(d.target?.rate, 96000)
        d.consume(event(rate("I/OLD", 0)), pid: 123)
        XCTAssertEqual(
            d.target?.rate, 96000, "late stop for the old item must not stop the new item")
        d.consume(event(change.replacingOccurrences(of: "P/JK", with: "P/VIDEO")), pid: 123)
        d.consume(
            event(current("I/NEXT").replacingOccurrences(of: "P/JK", with: "P/VIDEO")), pid: 123)
        XCTAssertEqual(d.target?.rate, 96000, "silent album artwork is not another audio player")
        d.consume(
            event(change.replacingOccurrences(of: "rate = 1.000", with: "rate = 0.000")), pid: 123)
        XCTAssertNil(d.target)
    }
    func testRestorationComparisonIncludesUIDAndWholeFormat() {
        let f = AudioStreamBasicDescription(
            mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: 9,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2,
            mBitsPerChannel: 32, mReserved: 0)
        let original = DeviceState(
            id: 78, uid: "speaker", rate: 48000,
            streams: [StreamState(id: 79, physical: f, virtual: f)])
        var target = original
        target.rate = 44100
        target.streams[0].physical.mSampleRate = 44100
        target.streams[0].virtual.mSampleRate = 44100
        XCTAssertTrue(original.isBetween(original, target))
        XCTAssertTrue(target.isBetween(original, target))
        var external = target
        external.rate = 96000
        XCTAssertFalse(external.isBetween(original, target))
        external = target
        external.streams[0].physical.mBitsPerChannel = 16
        XCTAssertFalse(external.isBetween(original, target))
        XCTAssertTrue(adequate(f))
        var low = f
        low.mFormatFlags = 12
        low.mBitsPerChannel = 16
        XCTAssertFalse(adequate(low))
        low.mBitsPerChannel = 24
        XCTAssertTrue(adequate(low))
    }
}
