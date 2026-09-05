import CoreAudio
import Foundation

enum AudioFailure: Error {
    case status(OSStatus)
    case invalid, unsupported, changed
}
func address(
    _ selector: AudioObjectPropertySelector,
    _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
        mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}
enum HAL {
    static func read<T>(
        _ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ type: T.Type,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) throws -> [T] {
        var a = address(selector, scope)
        var size: UInt32 = 0
        var s = AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size)
        guard s == noErr else { throw AudioFailure.status(s) }
        guard size <= 1_048_576, Int(size) % MemoryLayout<T>.stride == 0 else {
            throw AudioFailure.invalid
        }
        let p = UnsafeMutableRawPointer.allocate(
            byteCount: max(1, Int(size)), alignment: MemoryLayout<T>.alignment)
        defer { p.deallocate() }
        s = AudioObjectGetPropertyData(id, &a, 0, nil, &size, p)
        guard s == noErr else { throw AudioFailure.status(s) }
        return Array(
            UnsafeBufferPointer(
                start: p.assumingMemoryBound(to: T.self), count: Int(size) / MemoryLayout<T>.stride)
        )
    }
    static func one<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ type: T.Type)
        throws -> T
    {
        guard let x = try read(id, selector, type).first else { throw AudioFailure.invalid }
        return x
    }
    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) throws
        -> String
    {
        var a = address(selector)
        var n = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let p = UnsafeMutablePointer<Unmanaged<CFString>?>.allocate(capacity: 1)
        p.initialize(to: nil)
        defer {
            p.deinitialize(count: 1)
            p.deallocate()
        }
        let s = AudioObjectGetPropertyData(id, &a, 0, nil, &n, p)
        guard s == noErr, let v = p.pointee else { throw AudioFailure.status(s) }
        return v.takeRetainedValue() as String
    }
    static func write<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: T)
        throws
    {
        var a = address(selector)
        var settable: DarwinBoolean = false
        let s = AudioObjectIsPropertySettable(id, &a, &settable)
        guard s == noErr, settable.boolValue else { throw AudioFailure.unsupported }
        var value = value
        let result = withUnsafePointer(to: &value) {
            AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<T>.size), $0)
        }
        guard result == noErr else { throw AudioFailure.status(result) }
    }
    static func devices() throws -> [AudioDeviceID] {
        try read(1, kAudioHardwarePropertyDevices, UInt32.self)
    }
    static func defaultDevice() throws -> AudioDeviceID {
        try one(1, kAudioHardwarePropertyDefaultOutputDevice, UInt32.self)
    }
    static func rates(_ id: AudioDeviceID) throws -> [AudioValueRange] {
        try read(id, kAudioDevicePropertyAvailableNominalSampleRates, AudioValueRange.self)
    }
}

func sameFormat(_ a: AudioStreamBasicDescription, _ b: AudioStreamBasicDescription) -> Bool {
    a.mSampleRate == b.mSampleRate && a.mFormatID == b.mFormatID && a.mFormatFlags == b.mFormatFlags
        && a.mBytesPerPacket == b.mBytesPerPacket && a.mFramesPerPacket == b.mFramesPerPacket
        && a.mBytesPerFrame == b.mBytesPerFrame && a.mChannelsPerFrame == b.mChannelsPerFrame
        && a.mBitsPerChannel == b.mBitsPerChannel
}
func adequate(_ f: AudioStreamBasicDescription) -> Bool {
    guard f.mFormatID == kAudioFormatLinearPCM else { return false }
    return f.mFormatFlags & kAudioFormatFlagIsFloat != 0
        ? f.mBitsPerChannel >= 32 : f.mBitsPerChannel >= 24
}
func rateRanges(_ values: [AudioValueRange]) -> [ClosedRange<Double>] {
    values.compactMap { r in
        guard r.mMinimum.isFinite, r.mMaximum.isFinite, r.mMinimum > 0, r.mMinimum <= r.mMaximum
        else { return nil }
        return r.mMinimum...r.mMaximum
    }
}
func intersectRates(_ a: [ClosedRange<Double>], _ b: [ClosedRange<Double>]) -> [ClosedRange<Double>]
{
    Array(
        Set(
            a.flatMap { x in
                b.compactMap { y -> ClosedRange<Double>? in
                    let lower = max(x.lowerBound, y.lowerBound)
                    let upper = min(x.upperBound, y.upperBound)
                    return lower <= upper ? lower...upper : nil
                }
            }))
}
func chooseSampleRate(source: Double, ranges: [ClosedRange<Double>]) -> Double? {
    guard source.isFinite, source > 0 else { return nil }
    return ranges.compactMap { r -> Double? in
        guard r.lowerBound > 0, r.upperBound.isFinite else { return nil }
        let divisor = max(1, (source / r.upperBound).rounded(.up))
        let target = source / divisor
        return target.isFinite && r.contains(target) ? target : nil
    }.max()
}
func alignmentStatus(source: Double, output: Double, verified: Bool) -> String {
    let kind = source == output ? "aligned" : "downsampled"
    return
        "\(kind)-\(verified ? "verified" : "existing") source=\(source) Hz output=\(output) Hz divisor=\(source/output)"
}
struct StreamState: Equatable {
    let id: AudioStreamID
    var physical: AudioStreamBasicDescription
    var virtual: AudioStreamBasicDescription
    static func == (a: Self, b: Self) -> Bool {
        a.id == b.id && sameFormat(a.physical, b.physical) && sameFormat(a.virtual, b.virtual)
    }
}
struct DeviceState: Equatable {
    let id: AudioDeviceID
    let uid: String
    var rate: Double
    var streams: [StreamState]
    static func read(_ id: AudioDeviceID) throws -> Self {
        let uid = try HAL.string(id, kAudioDevicePropertyDeviceUID)
        let rate = try HAL.one(id, kAudioDevicePropertyNominalSampleRate, Double.self)
        let ids = try HAL.read(
            id, kAudioDevicePropertyStreams, UInt32.self, scope: kAudioObjectPropertyScopeOutput)
        guard !ids.isEmpty else { throw AudioFailure.invalid }
        return try Self(
            id: id, uid: uid, rate: rate,
            streams: ids.map {
                StreamState(
                    id: $0,
                    physical: try HAL.one(
                        $0, kAudioStreamPropertyPhysicalFormat, AudioStreamBasicDescription.self),
                    virtual: try HAL.one(
                        $0, kAudioStreamPropertyVirtualFormat, AudioStreamBasicDescription.self))
            })
    }
    func target(
        _ sourceRate: Double,
        nominalRates: (AudioDeviceID) throws -> [AudioValueRange] = HAL.rates,
        streamFormats: (AudioStreamID, AudioObjectPropertySelector) throws ->
            [AudioStreamRangedDescription] = {
                try HAL.read($0, $1, AudioStreamRangedDescription.self)
            }
    ) throws -> Self {
        var usable = rateRanges(try nominalRates(id))
        var formats: [[AudioStreamRangedDescription]] = []
        for s in streams {
            guard adequate(s.virtual) else { throw AudioFailure.unsupported }
            let physical = try streamFormats(s.id, kAudioStreamPropertyAvailablePhysicalFormats)
                .filter {
                    adequate($0.mFormat)
                        && $0.mFormat.mChannelsPerFrame == s.physical.mChannelsPerFrame
                }
            let virtual = try streamFormats(s.id, kAudioStreamPropertyAvailableVirtualFormats)
                .filter { option in
                    var f = option.mFormat
                    f.mSampleRate = s.virtual.mSampleRate
                    return sameFormat(f, s.virtual)
                }
            usable = intersectRates(usable, rateRanges(physical.map(\.mSampleRateRange)))
            usable = intersectRates(usable, rateRanges(virtual.map(\.mSampleRateRange)))
            formats.append(physical)
        }
        guard let rate = chooseSampleRate(source: sourceRate, ranges: usable) else {
            throw AudioFailure.unsupported
        }
        var result = self
        result.rate = rate
        for i in streams.indices {
            let old = streams[i].physical
            let options = formats[i]
            var preferred = old
            preferred.mSampleRate = rate
            let candidates = options.filter {
                $0.mSampleRateRange.mMinimum <= rate && rate <= $0.mSampleRateRange.mMaximum
                    && adequate($0.mFormat) && $0.mFormat.mChannelsPerFrame == old.mChannelsPerFrame
            }
            .map { value -> AudioStreamBasicDescription in
                var f = value.mFormat
                f.mSampleRate = rate
                return f
            }
            guard
                let chosen = candidates.first(where: { sameFormat($0, preferred) })
                    ?? candidates.sorted(by: { $0.mBitsPerChannel < $1.mBitsPerChannel }).first
            else { throw AudioFailure.unsupported }
            result.streams[i].physical = chosen
            result.streams[i].virtual.mSampleRate = rate
            guard adequate(result.streams[i].virtual) else { throw AudioFailure.unsupported }
        }
        return result
    }
    // Allow only known before/after values during an asynchronous HAL transition.
    func isBetween(_ before: Self, _ after: Self) -> Bool {
        guard id == before.id, uid == before.uid, id == after.id, uid == after.uid,
            rate == before.rate || rate == after.rate, streams.count == before.streams.count,
            streams.count == after.streams.count
        else { return false }
        return streams.indices.allSatisfy { i in
            let s = streams[i]
            let b = before.streams[i]
            let a = after.streams[i]
            return s.id == b.id && s.id == a.id
                && (sameFormat(s.physical, b.physical) || sameFormat(s.physical, a.physical))
                && (sameFormat(s.virtual, b.virtual) || sameFormat(s.virtual, a.virtual))
        }
    }
    func writeChanges(from old: Self) throws {
        guard try HAL.string(id, kAudioDevicePropertyDeviceUID) == uid else {
            throw AudioFailure.changed
        }
        for (a, b) in zip(streams, old.streams) where !sameFormat(a.physical, b.physical) {
            try HAL.write(a.id, kAudioStreamPropertyPhysicalFormat, a.physical)
        }
        if try HAL.one(id, kAudioDevicePropertyNominalSampleRate, Double.self) != rate {
            try HAL.write(id, kAudioDevicePropertyNominalSampleRate, rate)
        }
        for s in streams {
            let actual = try HAL.one(
                s.id, kAudioStreamPropertyVirtualFormat, AudioStreamBasicDescription.self)
            if !sameFormat(actual, s.virtual) {
                try HAL.write(s.id, kAudioStreamPropertyVirtualFormat, s.virtual)
            }
        }
    }
}

// HAL operations used by the controller and its tests.
struct AudioAccess {
    var defaultDevice: () throws -> AudioDeviceID = HAL.defaultDevice
    var read: (AudioDeviceID) throws -> DeviceState = DeviceState.read
    var target: (DeviceState, Double) throws -> DeviceState = { try $0.target($1) }
    var write: (DeviceState, DeviceState) throws -> Void = { try $0.writeChanges(from: $1) }
    var addListener:
        (AudioObjectID, AudioObjectPropertyAddress, @escaping AudioObjectPropertyListenerBlock) ->
            OSStatus = { id, a, block in
                var a = a
                return AudioObjectAddPropertyListenerBlock(id, &a, .main, block)
            }
    var removeListener:
        (AudioObjectID, AudioObjectPropertyAddress, @escaping AudioObjectPropertyListenerBlock) ->
            OSStatus = { id, a, block in
                var a = a
                return AudioObjectRemovePropertyListenerBlock(id, &a, .main, block)
            }
}

final class AudioControl {
    struct Lease {
        let original: DeviceState
        var expected: DeviceState
        var before: DeviceState
        var pending = false
        var returning = false
        var faultRollback = false
        var token = UUID()
        var source: SourceFormat?
    }
    private var leases: [String: Lease] = [:]
    private var yielded: Set<String> = []
    private var observed: [String: DeviceState] = [:]
    private var listeners:
        [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var lastAttempt: String?
    private var enabled = false
    var source: SourceFormat?
    var diagnostic = false
    var onStatus: ((String) -> Void)?
    var onIdle: (() -> Void)?
    private let access: AudioAccess
    init(access: AudioAccess = AudioAccess()) { self.access = access }

    func start() {
        enabled = true
        yielded.removeAll()
        lastAttempt = nil
        guard observe(1, kAudioHardwarePropertyDefaultOutputDevice),
            observe(1, kAudioHardwarePropertyDevices)
        else {
            enabled = false
            removeListeners(from: 0)
            onStatus?("control unavailable: critical system listener registration failed")
            return
        }
    }
    private func observe(
        _ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> Bool {
        let a = address(selector, scope)
        if listeners.contains(where: {
            $0.0 == id && $0.1.mSelector == a.mSelector && $0.1.mScope == a.mScope
                && $0.1.mElement == a.mElement
        }) {
            return true
        }
        let callback: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.changed() }
        let result = access.addListener(id, a, callback)
        guard result == noErr else {
            onStatus?(
                "listener-registration-failed object=\(id) selector=\(selector) status=\(result)")
            return false
        }
        listeners.append((id, a, callback))
        return true
    }
    private func watch(_ state: DeviceState) -> Bool {
        let start = listeners.count
        guard observe(state.id, kAudioDevicePropertyNominalSampleRate),
            observe(state.id, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput),
            state.streams.allSatisfy({
                observe($0.id, kAudioStreamPropertyPhysicalFormat)
                    && observe($0.id, kAudioStreamPropertyVirtualFormat)
            })
        else {
            removeListeners(from: start)
            return false
        }
        return true
    }
    private func removeListeners(from start: Int) {
        let removed = Array(listeners.dropFirst(start))
        listeners.removeSubrange(start...)
        for (id, a, block) in removed { _ = access.removeListener(id, a, block) }
    }
    func reconcile() {
        guard enabled else { return }
        let defaultID = try? access.defaultDevice()
        if let id = defaultID, let state = try? access.read(id), observed[state.uid] == nil,
            !yielded.contains(state.uid)
        {
            if watch(state) {
                observed[state.uid] = state
            } else {
                abandon(state.uid, "critical device listener registration failed")
            }
        }
        for (uid, l) in leases where l.original.id != defaultID && !l.returning {
            if l.pending { continue }
            restore(uid)
        }
        // The earlier read may have failed; a successful second read is not a listener baseline.
        guard let id = defaultID, let s = source, let current = try? access.read(id),
            observed[current.uid] != nil, !yielded.contains(current.uid)
        else { return }
        if leases[current.uid] == nil, let baseline = observed[current.uid], baseline != current {
            abandon(current.uid, "external change before acquisition")
            return
        }
        if let l = leases[current.uid] {
            guard !l.pending, !l.returning else { return }
            guard current == l.expected else {
                abandon(current.uid, "external change")
                return
            }
        }
        let key = "\(current.uid)|\(s.item)|\(s.rate)"
        guard lastAttempt != key else { return }
        lastAttempt = key
        do {
            let target = try access.target(current, s.rate)
            if target == current {
                onStatus?(alignmentStatus(source: s.rate, output: target.rate, verified: false))
                return
            }
            if diagnostic {
                onStatus?(
                    "would-set "
                        + alignmentStatus(source: s.rate, output: target.rate, verified: false))
                return
            }
            var l =
                leases[current.uid] ?? Lease(original: current, expected: current, before: current)
            l.before = current
            l.expected = target
            l.source = s
            leases[current.uid] = l
            begin(current.uid)
        } catch { onStatus?("unsupported-or-unreadable \(s.rate) Hz: \(error)") }
    }
    private func begin(_ uid: String) {
        guard var l = leases[uid] else { return }
        l.pending = true
        l.token = UUID()
        leases[uid] = l
        onStatus?(
            "write-start uid=\(uid) item=\(l.source?.item ?? "unknown") transaction=\(l.token) operation=\(l.returning ? "restore" : "align") output=\(l.expected.rate) Hz"
        )
        do { try access.write(l.expected, l.before) } catch {
            onStatus?("write-failed: \(error)")
            // Roll back only an observed mixture of this transaction's own values.
            if let actual = try? access.read(l.original.id), actual.isBetween(l.before, l.expected),
                !l.returning
            {
                l.before = actual
                l.expected = l.original
                l.returning = true
                l.faultRollback = true
                leases[uid] = l
                begin(uid)
            } else {
                abandon(uid, "write failed; control uncertain")
            }
            return
        }
        check(uid)
        let token = l.token
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, let value = self.leases[uid], value.token == token, value.pending else {
                return
            }
            self.check(uid)
            // check() can start a restore. The old timer must not act on its new token.
            if var remaining = self.leases[uid], remaining.token == token, remaining.pending {
                if !remaining.returning, let actual = try? self.access.read(remaining.original.id),
                    actual.isBetween(remaining.before, remaining.expected)
                {
                    self.onStatus?("verification timeout; rolling back observed own changes")
                    remaining.before = actual
                    remaining.expected = remaining.original
                    remaining.returning = true
                    remaining.faultRollback = true
                    self.leases[uid] = remaining
                    self.begin(uid)
                } else {
                    self.abandon(uid, "verification timeout; no success claimed")
                }
            }
        }
    }
    private func check(_ uid: String) {
        guard var l = leases[uid] else { return }
        guard let actual = try? access.read(l.original.id), actual.uid == uid else {
            abandon(uid, "disconnected/unreadable")
            return
        }
        if actual == l.expected {
            if l.pending {
                if l.returning {
                    if l.faultRollback {
                        onStatus?("fault-rollback-verified \(l.original.rate) Hz")
                        abandon(uid, "fault rollback completed; disabled for this Music session")
                    } else {
                        observed[uid] = actual
                        leases.removeValue(forKey: uid)
                        onStatus?(
                            "restored \(l.original.rate) Hz uid=\(uid) transaction=\(l.token)")
                        if !enabled && leases.isEmpty { finish() }
                    }
                } else {
                    l.pending = false
                    leases[uid] = l
                    onStatus?(
                        alignmentStatus(
                            source: l.source?.rate ?? actual.rate, output: actual.rate,
                            verified: true
                        ) + " uid=\(uid) item=\(l.source?.item ?? "unknown") transaction=\(l.token)"
                    )
                    if !enabled { restore(uid) }
                }
                DispatchQueue.main.async { [weak self] in self?.reconcile() }
            }
        } else if !l.pending || !actual.isBetween(l.before, l.expected) {
            abandon(uid, "external format change")
        }
    }
    private func abandon(_ uid: String, _ reason: String) {
        leases.removeValue(forKey: uid)
        observed.removeValue(forKey: uid)
        yielded.insert(uid)
        onStatus?("yielded: \(reason)")
        if !enabled && leases.isEmpty { finish() }
    }
    private func restore(_ uid: String) {
        guard var l = leases[uid], !l.pending else { return }
        guard let actual = try? access.read(l.original.id), actual == l.expected else {
            abandon(uid, "restore precondition changed")
            return
        }
        l.before = actual
        l.expected = l.original
        l.returning = true
        leases[uid] = l
        begin(uid)
    }
    private func changed() {
        for uid in Array(leases.keys) { check(uid) }
        for (uid, baseline) in observed where leases[uid] == nil && !yielded.contains(uid) {
            if (try? access.read(baseline.id)) != baseline {
                abandon(uid, "external change before acquisition")
            }
        }
        lastAttempt = nil
        reconcile()
    }
    func stop(completion: @escaping () -> Void) {
        enabled = false
        source = nil
        onIdle = completion
        for uid in Array(leases.keys) {
            check(uid)
            if leases[uid]?.pending == false { restore(uid) }
        }
        if leases.isEmpty { finish() }
    }
    private func finish() {
        removeListeners(from: 0)
        observed.removeAll()
        let done = onIdle
        onIdle = nil
        if let done { DispatchQueue.main.async(execute: done) }
    }
}
