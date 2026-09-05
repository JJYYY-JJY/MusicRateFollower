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
        var d = Detection()
        var rates = Set<Double>()
        for line in text.split(separator: "\n") {
            let x = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
            d.consume(x, pid: 80157)
            if let t = d.target { rates.insert(t.rate) }
        }
        XCTAssertEqual(rates, [44100, 48000, 96000, 192000])
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
