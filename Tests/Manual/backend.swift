import CoreAudio
import Foundation

@main struct LiveTests {
    static func check(_ value: Bool, _ message: String) throws {
        if !value {
            throw NSError(
                domain: "LiveTest", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
    static func wait(_ message: String, until ready: () throws -> Bool) throws {
        let deadline = Date().addingTimeInterval(3)
        repeat {
            if try ready() { return }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        } while Date() < deadline
        try check(false, message)
    }
    static func stop(_ c: AudioControl) throws {
        var done = false
        c.stop { done = true }
        try wait("restore did not complete") { done }
    }
    static func main() throws {
        setbuf(stdout, nil)
        let initialDefault = try HAL.defaultDevice()
        let states = try HAL.devices().compactMap { try? DeviceState.read($0) }
        var active: AudioControl?
        var failure: Error?
        do {
            for original in states {
                try HAL.write(1, kAudioHardwarePropertyDefaultOutputDevice, original.id)
                try wait("default output did not switch") { try HAL.defaultDevice() == original.id }
                let candidates: [Double] = [44100, 48000, 88200, 96000, 176400, 192000]
                var targets: [(Double, DeviceState)] = []
                var unsupported: [Double] = []
                for source in candidates {
                    do { targets.append((source, try original.target(source))) } catch AudioFailure
                        .unsupported
                    { unsupported.append(source) }
                }
                guard !targets.isEmpty else {
                    print("SKIP", original.uid, "no controllable lossless source formats")
                    continue
                }
                var lines: [String] = []
                let c = AudioControl()
                active = c
                c.onStatus = {
                    lines.append($0)
                    print(Date(), original.uid, $0)
                }
                c.start()
                for (source, expected) in targets {
                    c.source = SourceFormat(rate: source, bits: 24, item: "backend-\(source)")
                    c.reconcile()
                    try wait("full format was not verified for \(source)") {
                        try DeviceState.read(original.id) == expected
                    }
                    let writes = lines.filter { $0.hasPrefix("write-start") }.count
                    for _ in 0..<20 { c.reconcile() }
                    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                    try check(
                        lines.filter { $0.hasPrefix("write-start") }.count == writes,
                        "duplicate write")
                    print(
                        "PASS", original.uid, "source", source, "output", expected.rate,
                        "full format and repeat suppression")
                }
                let beforeUnsupported = try DeviceState.read(original.id)
                let writes = lines.filter { $0.hasPrefix("write-start") }.count
                for source in unsupported {
                    c.source = SourceFormat(rate: source, bits: 24, item: "unsupported-\(source)")
                    c.reconcile()
                }
                try check(
                    lines.filter { $0.hasPrefix("write-start") }.count == writes,
                    "unsupported source wrote settings")
                try check(
                    try DeviceState.read(original.id) == beforeUnsupported,
                    "unsupported source changed format")
                if unsupported.isEmpty {
                    print("SKIP", original.uid, "no unsupported source among verified source rates")
                }
                try stop(c)
                active = nil
                try check(
                    try DeviceState.read(original.id) == original, "did not restore first snapshot")
                print("PASS", original.uid, "multi-track first-snapshot restore")

                guard let (source, alternate) = targets.first(where: { $0.1 != original }) else {
                    print("SKIP", original.uid, "no alternate full format for external takeover")
                    continue
                }
                active = c
                c.start()
                c.source = nil
                c.reconcile()  // Observe the device before an external writer changes it.
                try alternate.writeChanges(from: original)
                try wait("external change not observed") {
                    try DeviceState.read(original.id) == alternate
                        && lines.contains { $0.hasPrefix("yielded:") }
                }
                c.source = SourceFormat(rate: source, bits: 24, item: "after-external-change")
                let externalWrites = lines.filter { $0.hasPrefix("write-start") }.count
                c.reconcile()
                try stop(c)
                active = nil
                try check(
                    lines.filter { $0.hasPrefix("write-start") }.count == externalWrites,
                    "reacquired external control")
                try check(
                    try DeviceState.read(original.id) == alternate,
                    "external change was overwritten")
                print("PASS", original.uid, "external change preserved through stop")
            }
        } catch { failure = error }
        if let active {
            do { try stop(active) } catch {
                print("FAIL controller cleanup", error)
                failure = error
            }
        }
        // Attempt every snapshot even if a previous test or cleanup failed.
        for original in states {
            do {
                let actual = try DeviceState.read(original.id)
                try check(actual.uid == original.uid, "device ID now belongs to another UID")
                try original.writeChanges(from: actual)
                try wait("snapshot restore did not settle") {
                    try DeviceState.read(original.id) == original
                }
            } catch {
                print("FAIL snapshot restore", original.uid, error)
                failure = error
            }
        }
        do {
            try HAL.write(1, kAudioHardwarePropertyDefaultOutputDevice, initialDefault)
            try wait("default output restore did not settle") {
                try HAL.defaultDevice() == initialDefault
            }
        } catch {
            print("FAIL default output restore", error)
            failure = error
        }
        if let failure { throw failure }
        print("PASS all original device snapshots and default output restored")
    }
}
