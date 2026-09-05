import AppKit
import CoreAudio
import Darwin
import Foundation
import OSLog

let logger = Logger(subsystem: "local.MusicRateFollower", category: "state")
func status(_ message: String) {
    logger.notice("\(message,privacy:.public)")
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    print("\(formatter.string(from: Date())) \(message)")
}

final class Follower {
    private var music: NSRunningApplication?
    private var stream: LogReader?
    private var history: LogReader?
    private let evidence = PlaybackEvidence()
    private var sleeping = false
    private var generation = UUID()
    private var observers: [NSObjectProtocol] = []
    private var signalSources: [DispatchSourceSignal] = []
    private var stopping = false
    private var endingSession = false
    private var lastSource: SourceFormat?
    private let audio = AudioControl()
    init(diagnostic: Bool) {
        audio.diagnostic = diagnostic
        audio.onStatus = status
        evidence.onInvalidated = { stamp in
            status("log evidence invalidated; waiting for records after \(stamp)")
        }
        evidence.onCancelHistory = { [weak self] in
            self?.history?.stop()
            self?.history = nil
        }
    }
    func start() {
        let nc = NSWorkspace.shared.notificationCenter
        observers.append(
            nc.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
            ) { [weak self] n in
                guard
                    let app = n.userInfo?[NSWorkspace.applicationUserInfoKey]
                        as? NSRunningApplication, app.bundleIdentifier == "com.apple.Music"
                else { return }
                self?.discover()
            })
        observers.append(
            nc.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
            ) { [weak self] n in
                guard let self,
                    let app = n.userInfo?[NSWorkspace.applicationUserInfoKey]
                        as? NSRunningApplication,
                    app.processIdentifier == self.music?.processIdentifier
                else { return }
                self.endSession()
            })
        observers.append(
            nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) {
                [weak self] _ in
                self?.sleeping = true
                self?.invalidateEvidence(suspended: true)
                status("evidence invalidated for sleep")
            })
        observers.append(
            nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
                [weak self] _ in
                self?.sleeping = false
                self?.invalidateEvidence(suspended: false)
                self?.discover()
                status("awake: waiting for fresh playback evidence")
            })
        observers.append(
            DistributedNotificationCenter.default().addObserver(
                forName: NSNotification.Name("com.apple.Music.playerInfo"), object: nil,
                queue: .main
            ) { [weak self] n in
                guard let self, self.music != nil,
                    let state = n.userInfo?["Player State"] as? String
                else { return }
                // This notification is an additional veto, never evidence authorizing a write.
                self.evidence.setPaused(state != "Playing")
                self.applySource()
            })
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            s.setEventHandler { [weak self] in self?.stop() }
            s.resume()
            signalSources.append(s)
        }
        discover()
    }
    private func discover() {
        guard !stopping, !endingSession, !sleeping else { return }
        guard
            let app = NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.apple.Music"
            ).first, !app.isTerminated
        else {
            status("waiting: Music is not running")
            return
        }
        guard app.processIdentifier != music?.processIdentifier else { return }
        music = app
        evidence.begin()
        lastSource = nil
        audio.start()
        status("Music started pid=\(app.processIdentifier)")
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 27 else {
            status("detection unavailable: only macOS 27 log dialect verified")
            return
        }
        let gen = UUID()
        generation = gen
        let reader = LogReader()
        stream = reader
        reader.onRecord = { [weak self] x in self?.record(x, gen: gen) }
        reader.onEnd = { [weak self] _ in
            guard let self, self.generation == gen else { return }
            self.generation = UUID()
            self.history?.stop()
            self.stream?.stop()
            self.history = nil
            self.stream = nil
            self.invalidateEvidence(suspended: self.sleeping)
            status("detection unavailable: log stream ended; retry on next Music launch")
        }
        let predicate = logPredicate + " AND processID == \(app.processIdentifier)"
        do {
            try reader.start([
                "stream", "--style", "ndjson", "--level", "default", "--predicate", predicate,
            ])
            let old = LogReader()
            history = old
            old.onRecord = { [weak self] x in self?.record(x, gen: gen, fromHistory: true) }
            old.onEnd = { [weak self] success in self?.finishBootstrap(gen: gen, success: success) }
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd HH:mm:ssZ"
            // Limit startup log scans to 30 minutes; older tracks need fresh playback evidence.
            let start = max(app.launchDate ?? Date(), Date().addingTimeInterval(-1800))
            try old.start([
                "show", "--style", "ndjson", "--start", f.string(from: start), "--predicate",
                predicate,
            ])
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                guard let self, self.generation == gen, self.evidence.bootstrapping else { return }
                self.history?.stop()
                self.finishBootstrap(gen: gen, success: false)
            }
        } catch {
            status("detection unavailable: \(error)")
            reader.stop()
            history?.stop()
            history = nil
            stream = nil
            generation = UUID()
            invalidateEvidence(suspended: sleeping)
        }
    }
    private func invalidateEvidence(suspended: Bool) {
        evidence.invalidate(suspended: suspended)
        lastSource = nil
        audio.source = nil
    }
    private func record(_ x: [String: Any], gen: UUID, fromHistory: Bool = false) {
        guard generation == gen, let app = music, !app.isTerminated else { return }
        evidence.receive(x, pid: app.processIdentifier, fromHistory: fromHistory)
        applySource()
    }
    private func finishBootstrap(gen: UUID, success: Bool) {
        guard generation == gen, evidence.bootstrapping, music != nil else { return }
        history = nil
        let accepted = evidence.finish(success: success)
        status(
            accepted
                ? "bootstrap complete (up to 30 minutes of current Music process)"
                : "bootstrap unavailable: waiting for fresh playback events")
        applySource()
    }
    private func applySource() {
        let target = evidence.target
        audio.source = target
        if target != lastSource {
            lastSource = target
            if let t = target {
                status("source-verified \(t.bits)-bit \(t.rate) Hz item=\(t.item)")
            } else {
                status("source unknown/paused; holding device settings")
            }
        }
        audio.reconcile()
    }
    private func endSession() {
        guard music != nil, !endingSession else { return }
        endingSession = true
        generation = UUID()
        stream?.stop()
        history?.stop()
        stream = nil
        history = nil
        invalidateEvidence(suspended: sleeping)
        music = nil
        status("Music ended; restoring owned devices")
        audio.stop { [weak self] in
            guard let self else { return }
            self.endingSession = false
            if self.stopping { exit(0) } else { self.discover() }
        }
    }
    private func stop() {
        guard !stopping else { return }
        stopping = true
        if music == nil && !endingSession { exit(0) }
        endSession()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            status("shutdown deadline reached")
            exit(1)
        }
    }
}

setbuf(stdout, nil)
let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "--log-child" {
    let parent = getppid()
    let group = getpgid(parent)
    guard parent > 1, group > 0, setpgid(0, group) == 0 else { exit(1) }
    signal(SIGTERM, SIG_DFL)
    signal(SIGINT, SIG_DFL)
    signal(SIGPIPE, SIG_DFL)
    let strings = (["/usr/bin/log"] + arguments.dropFirst()).map { strdup($0) }
    var argv = strings + [nil]
    execv("/usr/bin/log", &argv)
    for p in strings { free(p) }
    exit(1)
}
if arguments == ["--devices"] {
    do {
        for id in try HAL.devices() {
            guard let state = try? DeviceState.read(id) else { continue }
            let rates = try HAL.rates(id).map { "\($0.mMinimum)-\($0.mMaximum)" }.joined(
                separator: ", ")
            print(
                "\(id) \(try HAL.string(id,kAudioObjectPropertyName))\(try HAL.defaultDevice() == id ? " [default]" : "")"
            )
            print("  rate=\(state.rate), supported=[\(rates)]")
            for s in state.streams {
                print(
                    "  physical=\(s.physical.mBitsPerChannel)-bit flags=\(s.physical.mFormatFlags), virtual=\(s.virtual.mBitsPerChannel)-bit flags=\(s.virtual.mFormatFlags)"
                )
            }
        }
    } catch {
        status("device query failed: \(error)")
        exit(1)
    }
    exit(0)
}
guard arguments.isEmpty || arguments == ["--diagnose"] else {
    print("Usage: MusicRateFollower [--diagnose | --devices]")
    exit(64)
}
let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("MusicRateFollower")
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
let lockFD = open(
    folder.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC,
    0o600)
guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
    status("another instance is already running")
    exit(1)
}
let follower = Follower(diagnostic: arguments == ["--diagnose"])
follower.start()
RunLoop.main.run()
