import Darwin
import Foundation

struct SourceFormat: Equatable {
    let rate: Double
    let bits: Int
    let item: String
}

// The macOS 27 format is deliberately allowlisted. Numbers in arbitrary messages,
// decoder creation, output formats and preloaded items are never source evidence.
struct Detection {
    struct Player {
        var current: String?
        var rates: [String: Double] = [:]
        var formats: [String: SourceFormat] = [:]
        var audioItems: Set<String> = []
    }
    var players: [String: Player] = [:]
    var paused = false
    private static let current = try! NSRegularExpression(
        pattern:
            #"<(?<player>P/[^|>]+)\|[^>]+> currentItem KVO: updating current item from \S+ to (?<item>\S+)"#
    )
    private static let identity = try! NSRegularExpression(
        pattern: #"\|(?<player>P/[^\]]+)\]\s*:?\s*<[^|>]+\|(?<item>I/[^>]+)>"#)
    private static let rate = try! NSRegularExpression(
        pattern: #"rate (?<rate>[0-9]+(?:\.[0-9]+)?) set on track [0-9]+ \(audio\)"#)
    private static let itemRate = try! NSRegularExpression(
        pattern: #"called at [^,]+, rate = (?<rate>-?[0-9]+(?:\.[0-9]+)?),"#)
    private static let format = try! NSRegularExpression(
        pattern: #"\[SampleRate (?<rate>[0-9]+)\] \[BitDepth (?<bits>[0-9]+)\]"#)

    static func field(_ re: NSRegularExpression, _ name: String, _ s: String) -> String? {
        guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
            let r = Range(m.range(withName: name), in: s)
        else { return nil }
        return String(s[r])
    }
    mutating func consume(_ x: [String: Any], pid: Int32) {
        guard (x["processID"] as? NSNumber)?.int32Value == pid,
            (x["processImagePath"] as? String)
                == "/System/Applications/Music.app/Contents/MacOS/Music",
            x["subsystem"] as? String == "com.apple.coremedia",
            let m = x["eventMessage"] as? String
        else { return }
        if m.contains("currentItem KVO: updating"),
            let p = Self.field(Self.current, "player", m),
            let item = Self.field(Self.current, "item", m)
        {
            var v = players[p] ?? Player()
            let next = item.hasPrefix("I/") ? item : nil
            if v.current != next {
                v.current = next
                // Rate events may precede currentItem KVO. Only preserve that item's state.
                v.rates = v.rates.filter { $0.key == next }
                v.formats = v.formats.filter { $0.key == next }
                v.audioItems = v.audioItems.filter { $0 == next }
            }
            players[p] = v
        } else if let p = Self.field(Self.identity, "player", m),
            let item = Self.field(Self.identity, "item", m)
        {
            var v = players[p] ?? Player()
            if m.contains("fpfs_SetRateOnTrack:"), let r = Self.field(Self.rate, "rate", m),
                let rate = Double(r)
            {
                v.rates[item] = rate
                v.audioItems.insert(item)
            } else if m.contains("fpfs_SetRateWithOptionsAndAnchorTime:"),
                let r = Self.field(Self.itemRate, "rate", m), let rate = Double(r)
            {
                v.rates[item] = rate
            } else if m.contains("fpfs_StopPlayingItem:"), m.contains(": Stopping") {
                v.rates[item] = 0
                v.formats.removeValue(forKey: item)
            } else if m.contains("fpfs_ReportAudioPlaybackThroughFigLog:") {
                v.audioItems.insert(item)
                v.formats.removeValue(forKey: item)
                if m.contains("[AudioFormat qlac is  decodable]"),
                    m.contains("[Rendition Lossless]"),
                    m.contains("[AudioChannels 2]"), m.contains("[Spatialization no]"),
                    m.contains("[StereoSpatialization no]"), m.contains("[Immersive rendering no]"),
                    let r = Self.field(Self.format, "rate", m), let rate = Double(r),
                    let b = Self.field(Self.format, "bits", m), let bits = Int(b),
                    [16, 24].contains(bits),
                    [44100, 48000, 88200, 96000, 176400, 192000].contains(rate)
                {
                    v.formats[item] = SourceFormat(rate: rate, bits: bits, item: item)
                }
                if v.formats.count > 8 { v.formats = v.formats.filter { $0.key == v.current } }
                if v.audioItems.count > 8 { v.audioItems = v.audioItems.filter { $0 == v.current } }
            }
            if v.rates.count > 8 { v.rates = v.rates.filter { $0.key == v.current } }
            players[p] = v
        }
        // Bounded even if a future OS emits unbounded player identities.
        if players.count > 32 { players.removeAll() }
    }
    var target: SourceFormat? {
        guard !paused else { return nil }
        let active = players.values.filter { v in
            guard let item = v.current else { return false }
            return (v.rates[item] ?? 0) > 0 && v.audioItems.contains(item)
        }
        guard active.count == 1, let v = active.first, let item = v.current else { return nil }
        return v.formats[item]
    }
}

let logPredicate =
    #"process == "Music" AND subsystem == "com.apple.coremedia" AND (eventMessage CONTAINS "fpfs_ReportAudioPlaybackThroughFigLog:" OR (eventMessage CONTAINS "fpfs_SetRateOnTrack:" AND eventMessage CONTAINS "(audio)") OR (eventMessage CONTAINS "fpfs_SetRateWithOptionsAndAnchorTime:" AND eventMessage CONTAINS "called at") OR eventMessage CONTAINS "fpfs_StopPlayingItem:" OR eventMessage CONTAINS "currentItem KVO: updating")"#

// Shared by the live follower and isolated bootstrap/invalidation tests.
final class PlaybackEvidence {
    private var detection = Detection()
    private var pendingRecords: [[String: Any]] = []
    private(set) var bootstrapping = false
    private(set) var lastStamp: UInt64 = 0
    private var minimumStamp: UInt64 = 0
    private var suspended = false
    var onCancelHistory: (() -> Void)?
    let now: () -> UInt64
    init(now: @escaping () -> UInt64 = mach_continuous_time) { self.now = now }
    var target: SourceFormat? { bootstrapping || suspended ? nil : detection.target }
    func begin() {
        detection = Detection()
        pendingRecords = []
        lastStamp = minimumStamp
        bootstrapping = !suspended
    }
    func setPaused(_ value: Bool) { detection.paused = value }
    func invalidate(at stamp: UInt64? = nil, suspended: Bool = false) {
        // Unified log machTimestamp uses the continuous clock, including sleep.
        minimumStamp = max(minimumStamp, max(lastStamp, max(now(), stamp ?? 0)))
        lastStamp = minimumStamp
        let paused = detection.paused
        detection = Detection()
        detection.paused = paused
        pendingRecords = []
        self.suspended = suspended
        let cancel = bootstrapping
        bootstrapping = false
        if cancel { onCancelHistory?() }
    }
    func receive(_ x: [String: Any], pid: Int32, fromHistory: Bool = false) {
        guard !suspended, !fromHistory || bootstrapping else { return }
        if x["eventType"] as? String == "lossEvent" {
            invalidate(at: (x["machTimestamp"] as? NSNumber)?.uint64Value)
            return
        }
        guard x["eventMessage"] is String,
            let stamp = (x["machTimestamp"] as? NSNumber)?.uint64Value, stamp > minimumStamp
        else { return }
        if bootstrapping {
            guard pendingRecords.count < 4096 else {
                invalidate()
                return
            }
            pendingRecords.append(x)
        } else {
            guard stamp > lastStamp else { return }
            lastStamp = stamp
            detection.consume(x, pid: pid)
        }
    }
    func finish(success: Bool, pid: Int32) {
        guard bootstrapping, !suspended else { return }
        guard success else {
            invalidate()
            return
        }
        bootstrapping = false
        let sorted = pendingRecords.sorted {
            ($0["machTimestamp"] as? NSNumber)?.uint64Value ?? 0
                < ($1["machTimestamp"] as? NSNumber)?.uint64Value ?? 0
        }
        for x in sorted {
            guard let stamp = (x["machTimestamp"] as? NSNumber)?.uint64Value, stamp > lastStamp
            else { continue }
            lastStamp = stamp
            detection.consume(x, pid: pid)
        }
        pendingRecords = []
    }
}

// All callbacks are delivered on the main queue. No periodic timers.
final class LogReader {
    private var process: Process?
    private var pipe: Pipe?
    private let readerQueue = DispatchQueue(label: "MusicRateFollower.log")
    private var buffer = Data()
    var onRecord: (([String: Any]) -> Void)?
    var onEnd: ((Bool) -> Void)?

    func start(_ args: [String]) throws {
        let p = Process()
        let out = Pipe()
        // Foundation creates a separate child process group. Re-exec once to join
        // the LaunchAgent's group before exec(log), so launchd can reap it on SIGKILL.
        p.executableURL = Bundle.main.executableURL
        p.arguments = ["--log-child"] + args
        p.standardOutput = out
        p.standardError = FileHandle.standardError
        pipe = out
        process = p
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard let self else { return }
            self.readerQueue.async {
                if data.isEmpty {
                    h.readabilityHandler = nil
                    p.waitUntilExit()
                    DispatchQueue.main.async { self.onEnd?(p.terminationStatus == 0) }
                    return
                }
                self.buffer.append(data)
                guard self.buffer.count <= 1_048_576 else {
                    self.buffer.removeAll()
                    DispatchQueue.main.async {
                        self.onEnd?(false)
                        self.stop()
                    }
                    return
                }
                while let end = self.buffer.firstIndex(of: 10) {
                    let line = self.buffer.prefix(upTo: end)
                    let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
                    self.buffer.removeSubrange(...end)
                    if let obj {
                        DispatchQueue.main.async { self.onRecord?(obj) }
                    } else if !line.isEmpty,
                        !String(decoding: line, as: UTF8.self).hasPrefix(
                            "Filtering the log data using")
                    {
                        DispatchQueue.main.async {
                            self.onEnd?(false)
                            self.stop()
                        }
                        return
                    }
                }
            }
        }
        try p.run()
    }
    func stop() {
        onRecord = nil
        onEnd = nil
        pipe?.fileHandleForReading.readabilityHandler = nil
        if let p = process, p.isRunning {
            // Process.terminate assumes its original process group. Our child joined
            // the agent group, so address its PID explicitly, never the agent group.
            _ = Darwin.kill(p.processIdentifier, SIGTERM)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                if p.isRunning { _ = Darwin.kill(p.processIdentifier, SIGKILL) }
            }
        }
        if let p = process {
            readerQueue.async { p.waitUntilExit() }
        }
        pipe = nil
        process = nil
    }
    deinit { stop() }
}
