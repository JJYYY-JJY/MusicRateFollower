import CoreAudio
import Foundation

@main struct LiveTests {
    static func main() throws {
        func check(_ value: Bool, _ message: String = "check failed") throws {
            if !value {
                throw NSError(
                    domain: "LiveTest", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
        setbuf(stdout, nil)
        let initialDefault = try HAL.defaultDevice()
        let states = try HAL.devices().compactMap { try? DeviceState.read($0) }
        defer {
            for original in states {
                if let actual = try? DeviceState.read(original.id) {
                    try? original.writeChanges(from: actual)
                }
            }
            try? HAL.write(1, kAudioHardwarePropertyDefaultOutputDevice, initialDefault)
        }
        func pump(_ seconds: Double = 0.5) {
            RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        }
        func stop(_ c: AudioControl) throws {
            var done = false
            c.stop { done = true }
            pump(1.2)
            try check(done, "restore did not complete")
        }
        for original in states {
            try HAL.write(1, kAudioHardwarePropertyDefaultOutputDevice, original.id)
            pump()
            var lines: [String] = []
            let c = AudioControl()
            c.onStatus = {
                lines.append($0)
                print(original.id, $0)
            }
            c.start()
            let rate: Double = original.rate == 44100 ? 48000 : 44100
            c.source = SourceFormat(rate: rate, bits: 24, item: "live-test-1")
            c.reconcile()
            pump()
            try check(try DeviceState.read(original.id).rate == rate)
            let writes = lines.filter { $0.hasPrefix("aligned-verified") }.count
            for _ in 0..<20 { c.reconcile() }
            pump()
            try check(lines.filter { $0.hasPrefix("aligned-verified") }.count == writes)
            let maximum = try HAL.rates(original.id).map(\.mMaximum).max()!
            c.source = SourceFormat(rate: 192000, bits: 24, item: "integer-fallback")
            c.reconcile()
            pump()
            try check(
                try DeviceState.read(original.id).rate == maximum,
                "192 kHz fallback did not reach supported maximum")
            let fallbackWrites = lines.filter { $0.hasPrefix("downsampled-verified") }.count
            for _ in 0..<20 { c.reconcile() }
            pump()
            try check(lines.filter { $0.hasPrefix("downsampled-verified") }.count == fallbackWrites)
            c.source = SourceFormat(rate: 176400, bits: 24, item: "integer-fallback-441-family")
            c.reconcile()
            pump()
            let ranges = try HAL.rates(original.id)
            let expected176 = (1...512).map { 176400.0 / Double($0) }.first { rate in
                ranges.contains { $0.mMinimum <= rate && rate <= $0.mMaximum }
            }!
            try check(try DeviceState.read(original.id).rate == expected176)
            c.source = SourceFormat(rate: rate, bits: 24, item: "return-before-unsupported")
            c.reconcile()
            pump()
            c.source = SourceFormat(rate: 32000, bits: 24, item: "unsupported")
            c.reconcile()
            pump()
            try check(try DeviceState.read(original.id).rate == rate)
            c.source = SourceFormat(rate: original.rate, bits: 24, item: "live-test-2")
            c.reconcile()
            pump()
            c.source = SourceFormat(rate: rate, bits: 24, item: "live-test-3")
            c.reconcile()
            pump()
            try stop(c)
            try check(
                try DeviceState.read(original.id) == original, "did not restore first snapshot")
            print(
                "PASS", original.id,
                "192/176.4 kHz fallback, repeat suppression, unsupported, multi-track first-snapshot restore"
            )

            let yielded = AudioControl()
            yielded.onStatus = { print(original.id, $0) }
            yielded.start()
            yielded.source = SourceFormat(rate: original.rate, bits: 24, item: "already-aligned")
            yielded.reconcile()
            pump()
            try HAL.write(original.id, kAudioDevicePropertyNominalSampleRate, rate)
            pump()
            yielded.source = SourceFormat(rate: original.rate, bits: 24, item: "after-user-change")
            yielded.reconcile()
            pump()
            try check(try DeviceState.read(original.id).rate == rate)
            try stop(yielded)
            try check(try DeviceState.read(original.id).rate == rate)
            try original.writeChanges(from: DeviceState.read(original.id))
            pump()
            print("PASS", original.id, "external change while already aligned is preserved")
        }
    }
}
