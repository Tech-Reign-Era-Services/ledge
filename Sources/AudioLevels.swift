import AudioToolbox
import CoreAudio
import Foundation

// The music bars, moving to the music itself. While Music or Spotify plays, a Core Audio tap listens to that app's
// output only (macOS 14.2+, asks once for System Audio Recording), splits it into four bands, bass to treble, and
// hands out a level for each ~30 times a second. Nothing runs while nothing plays. Without the tap (older macOS, or
// permission refused), onLevels gets nil and the bars keep their own animation.

final class AudioLevels {
    static let bands = 4
    var onLevels: (([Double]?) -> Void)?

    private var bundleID: String?
    private var tap: AnyObject? // ProcessTap, kept untyped so this file still builds for macOS 13
    private var timer: Timer?
    private var retry: DispatchWorkItem?
    private var shown: [Double] = Array(repeating: 0, count: AudioLevels.bands)
    private var peak: [Double] = Array(repeating: -30, count: AudioLevels.bands) // dB, follows the loudest recent level
    private var mean: [Double] = Array(repeating: -40, count: AudioLevels.bands) // dB, the last half second or so
    private var quiet = 0

    /// Follow this app's audio, or stop (nil): called whenever what's playing changes.
    func follow(_ bundleID: String?) {
        if bundleID == self.bundleID { return }
        stop()
        self.bundleID = bundleID
        if bundleID != nil { start(attempt: 0) }
    }

    private func start(attempt: Int) {
        guard #available(macOS 14.2, *), let bundleID else { onLevels?(nil); return }
        guard let t = ProcessTap(bundleID: bundleID) else {
            // The player may not have opened its audio output yet: try again for a few seconds.
            if attempt < 5 {
                let work = DispatchWorkItem { [weak self] in self?.start(attempt: attempt + 1) }
                retry = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
            } else { onLevels?(nil) }
            if Island.debug { NSLog("audio tap for %@ not ready (attempt %d)", bundleID, attempt) }
            return
        }
        t.onDeviceChange = { [weak self] in // headphones plugged in, AirPods connected…: tap again
            guard let self, let id = self.bundleID else { return }
            self.stop(); self.bundleID = id; self.start(attempt: 0)
        }
        tap = t
        quiet = 0
        timer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func stop() {
        retry?.cancel(); retry = nil
        timer?.invalidate(); timer = nil
        if #available(macOS 14.2, *) { (tap as? ProcessTap)?.close() }
        tap = nil
        bundleID = nil
        shown = Array(repeating: 0, count: AudioLevels.bands)
        onLevels?(nil)
    }

    private func tick() {
        guard #available(macOS 14.2, *), let t = tap as? ProcessTap else { return }
        guard let energy = t.take() else { return } // no audio since the last tick
        // Pure silence for a couple of seconds usually means the permission was refused: fall back to the animation.
        // A few seconds more (or a player that went away without saying so), and let go of the tap altogether: while
        // it runs, Core Audio keeps the Mac from sleeping. It starts again when the music does.
        if energy.allSatisfy({ $0 == 0 }) {
            quiet += 1
            if quiet == 60 { onLevels?(nil) }
            if quiet == 240 { let id = bundleID; stop(); bundleID = id } // same id: follow() won't restart it until the music changes
            return
        }
        quiet = 0
        for i in 0..<AudioLevels.bands {
            let db = 10 * log10(energy[i] + 1e-12)
            peak[i] = max(db, peak[i] - 0.15, -70) // loud parts set the scale, which relaxes slowly after them
            mean[i] += (db - mean[i]) * 0.08
            // Mostly how far this moment stands out from the last half second (the beat), a little of how loud it is.
            let beat = (db - mean[i]) / 8
            let loud = (db - peak[i]) / 30
            let v = min(1, max(0.08, 0.42 + beat + loud))
            shown[i] = max(v, shown[i] * 0.72) // jump up, fall back quickly enough to show the next hit
        }
        if Island.debug, Int(Date().timeIntervalSince1970 * 30) % 30 == 0 { NSLog("levels %@", shown.map { String(format: "%.2f", $0) }.joined(separator: " ")) }
        onLevels?(shown)
    }
}

/// A Core Audio tap on every audio process of one app (Spotify plays from a helper), read through a private
/// aggregate device. The audio still plays as usual: the tap only listens.
@available(macOS 14.2, *)
private final class ProcessTap {
    var onDeviceChange: (() -> Void)?
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "ledge.audio", qos: .userInteractive)
    private let lock = NSLock()
    private var sums = [Double](repeating: 0, count: AudioLevels.bands)
    private var frames = 0
    private var lp = [Double](repeating: 0, count: 4) // one-pole low-passes at the band edges
    private var coef = [Double](repeating: 0, count: 4)
    private var listener: AudioObjectPropertyListenerBlock?

    init?(bundleID: String) {
        let processes = ProcessTap.processes(of: bundleID)
        if processes.isEmpty { return nil }

        let desc = CATapDescription(stereoMixdownOfProcesses: processes)
        desc.name = "Ledge music bars"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        guard AudioHardwareCreateProcessTap(desc, &tapID) == noErr else { return nil }

        var fmt = AudioStreamBasicDescription()
        guard ProcessTap.get(tapID, kAudioTapPropertyFormat, &fmt) else { close(); return nil }
        let rate = fmt.mSampleRate > 0 ? fmt.mSampleRate : 48000
        // Bands: bass below 150 Hz, then 150–600, 600–2.5k and 2.5k–8k.
        coef = [150.0, 600, 2500, 8000].map { 1 - exp(-2 * Double.pi * $0 / rate) }

        let output = ProcessTap.defaultOutputUID() ?? ""
        var agg: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Ledge music bars",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        if !output.isEmpty {
            agg[kAudioAggregateDeviceMainSubDeviceKey] = output
            agg[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: output]]
        }
        guard AudioHardwareCreateAggregateDevice(agg as CFDictionary, &deviceID) == noErr else { close(); return nil }

        let channels = max(1, Int(fmt.mChannelsPerFrame))
        let interleaved = fmt.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        let ok = AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, queue) { [weak self] _, input, _, _, _ in
            self?.analyse(UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)), channels: channels, interleaved: interleaved)
        }
        guard ok == noErr, AudioDeviceStart(deviceID, procID) == noErr else { close(); return nil }

        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.onDeviceChange?() }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, block) == noErr { listener = block }
    }

    func close() {
        if let listener {
            var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                  mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, listener)
            self.listener = nil
        }
        if deviceID != kAudioObjectUnknown {
            if let procID { AudioDeviceStop(deviceID, procID); AudioDeviceDestroyIOProcID(deviceID, procID) }
            AudioHardwareDestroyAggregateDevice(deviceID)
            deviceID = AudioObjectID(kAudioObjectUnknown)
        }
        procID = nil
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID); tapID = AudioObjectID(kAudioObjectUnknown) }
    }

    deinit { close() }

    /// The mean energy in each band since the last call, or nil if no audio arrived.
    func take() -> [Double]? {
        lock.lock(); defer { lock.unlock() }
        guard frames > 0 else { return nil }
        let out = sums.map { $0 / Double(frames) }
        sums = [Double](repeating: 0, count: AudioLevels.bands)
        frames = 0
        return out
    }

    private func analyse(_ buffers: UnsafeMutableAudioBufferListPointer, channels: Int, interleaved: Bool) {
        guard let first = buffers.first, let data = first.mData else { return }
        let n = interleaved ? Int(first.mDataByteSize) / 4 / channels : Int(first.mDataByteSize) / 4
        guard n > 0 else { return }
        var a0 = 0.0, a1 = 0.0, a2 = 0.0, a3 = 0.0
        var l0 = lp[0], l1 = lp[1], l2 = lp[2], l3 = lp[3]
        let c0 = coef[0], c1 = coef[1], c2 = coef[2], c3 = coef[3]
        for f in 0..<n {
            var x = 0.0 // mono
            if interleaved {
                let p = data.assumingMemoryBound(to: Float.self)
                for c in 0..<channels { x += Double(p[f * channels + c]) }
                x /= Double(channels)
            } else {
                for b in buffers { if let d = b.mData { x += Double(d.assumingMemoryBound(to: Float.self)[f]) } }
                x /= Double(buffers.count)
            }
            l0 += c0 * (x - l0); l1 += c1 * (x - l1); l2 += c2 * (x - l2); l3 += c3 * (x - l3)
            let b1 = l1 - l0, b2 = l2 - l1, b3 = l3 - l2
            a0 += l0 * l0; a1 += b1 * b1; a2 += b2 * b2; a3 += b3 * b3
        }
        lp = [l0, l1, l2, l3]
        lock.lock()
        sums[0] += a0; sums[1] += a1; sums[2] += a2; sums[3] += a3
        frames += n
        lock.unlock()
    }

    // ---------- Core Audio lookups ----------

    private static func get<T>(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, $0) } == noErr
    }

    /// Every audio process belonging to the app: its own, and its helpers' (com.spotify.client.helper…).
    private static func processes(of bundleID: String) -> [AudioObjectID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter { id in
            var name: Unmanaged<CFString>?
            guard get(id, kAudioProcessPropertyBundleID, &name), let s = name?.takeRetainedValue() as String? else { return false }
            return s == bundleID || s.hasPrefix(bundleID + ".")
        }
    }

    private static func defaultOutputUID() -> String? {
        var device = AudioObjectID(kAudioObjectUnknown)
        guard get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, &device) else { return nil }
        var uid: Unmanaged<CFString>?
        guard get(device, kAudioDevicePropertyDeviceUID, &uid) else { return nil }
        return uid?.takeRetainedValue() as String?
    }
}
