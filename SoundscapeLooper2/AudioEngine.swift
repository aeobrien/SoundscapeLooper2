import Foundation
import AVFoundation

// MARK: - Loop bookkeeping
struct LoopRegion { public var startSample: Int; public var lengthSamples: Int }

// MARK: - Engine

final class AudioEngineManager: ObservableObject {

    // ===== Public knobs (same API names as your yesterday build) =====
    @Published var bpm: Double = 120
    @Published public var crossfadeMs: Double = 5          // kept for API compat; not used in this minimal chain
    @Published public var widthScale: Double = 1
    @Published public var anchorSample: Int = 0

    // File data (readable by UI)
    @Published public private(set) var fileBuffer: AVAudioPCMBuffer?
    public private(set) var sampleRate: Double = 44100
    public private(set) var fileLengthSamples: Int = 0
    public private(set) var channelCount: Int = 2

    // ===== Internals =====
    private let engine = AVAudioEngine()
    private var players: [UUID: AVAudioPlayerNode] = [:]
    private var voiceRegions: [UUID: LoopRegion] = [:]
    private var bufferCache: [UUID: AVAudioPCMBuffer] = [:]
    private var activeVoices: [UUID: VoiceConfig] = [:]
    private var tombstonedVoices: Set<UUID> = []

    // per-voice scheduling state
    private var needsRebuildNextCycle: Set<UUID> = []
    private var isStartedForVoice: Set<UUID> = []
    
    // Playhead tracking
    @Published public private(set) var playheads: [UUID: Int] = [:]
    private var meterTimer: Timer?

    public init() {
        // macOS: no AVAudioSession needed
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)
        try? engine.start()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { [weak self] _ in
            self?.updatePlayheads()
        }
    }

    // MARK: - Public API

    func loadFile(url: URL) throws {
        stopAll()
        players.removeAll()
        bufferCache.removeAll()
        voiceRegions.removeAll()
        activeVoices.removeAll()
        needsRebuildNextCycle.removeAll()
        isStartedForVoice.removeAll()

        let f = try AVAudioFile(forReading: url)
        sampleRate = f.processingFormat.sampleRate
        channelCount = Int(f.processingFormat.channelCount)
        fileLengthSamples = Int(f.length)

        let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat,
                                   frameCapacity: AVAudioFrameCount(f.length))!
        try f.read(into: buf)
        fileBuffer = buf

        // default anchor to centre if unset
        anchorSample = min(max(anchorSample, 0), max(0, fileLengthSamples - 1))
        if anchorSample == 0 { anchorSample = fileLengthSamples / 2 }
    }

    /// Old “apply changes” entrypoint. Safe to call; it no longer hard-restarts.
    func renderAndSchedule(voices: [VoiceConfig]) {
        markCycleParamsChanged(voices: voices)
        startAnyVoicesThatNeedIt()
    }

    /// Call this on anchor/length/bpm/width/voices changes. No stop/rebuild; just mark dirty.
    func markCycleParamsChanged(voices: [VoiceConfig]) {
        // keep a copy of the latest voice configs
        voices.forEach { activeVoices[$0.id] = $0 }
        // recompute regions for everyone based on latest globals
        computeRegions(for: voices)
        // mark each voice to rebuild its buffer on the next boundary
        voices.forEach { needsRebuildNextCycle.insert($0.id) }
    }

    /// Instant knobs (mute/solo/volume/pan) — apply immediately.
    func liveAdjust(for v: VoiceConfig) {
        activeVoices[v.id] = v
        if let n = players[v.id] {
            n.volume = v.mute ? 0 : v.volume
            n.pan    = v.pan
        }
    }


    func stopAll() {
        // mark all current voices as tombstoned so any pending completions no-op
        tombstonedVoices = Set(players.keys)
        // stop safely
        players.values.forEach { $0.stop() }
        isStartedForVoice.removeAll()
    }


    func removePlayer(for id: UUID) {
        // ensure any in-flight completion won't reschedule
        tombstonedVoices.insert(id)

        if let n = players.removeValue(forKey: id) {
            n.stop()
            engine.disconnectNodeInput(n)
            engine.detach(n)
        }
        bufferCache[id] = nil
        voiceRegions[id] = nil
        activeVoices[id] = nil
        needsRebuildNextCycle.remove(id)
        isStartedForVoice.remove(id)
    }


    // MARK: - Regions

    public func region(for id: UUID) -> LoopRegion? { voiceRegions[id] }
    
    private func updatePlayheads() {
        for (id, node) in players {
            guard let v = activeVoices[id],
                  let region = voiceRegions[id],
                  let nodeTime = node.lastRenderTime,
                  let ptime = node.playerTime(forNodeTime: nodeTime) else { continue }
            // position within current scheduled buffer (frames)
            let frame = Int(ptime.sampleTime % AVAudioFramePosition(region.lengthSamples))
            playheads[id] = region.startSample + frame
        }
    }
    
    private func nearestZeroCrossing(around sample: Int, search: Int = 1024) -> Int {
        guard let buf = fileBuffer, let s0 = buf.floatChannelData?[0] else { return sample }
        let lo = max(1, sample - search)
        let hi = min(fileLengthSamples - 2, sample + search)
        var best = sample
        var bestAbs: Float = .greatestFiniteMagnitude
        for i in lo..<hi {
            // zero-crossing when sign changes; choose the point closest to zero
            let a = s0[i - 1]
            let b = s0[i]
            if (a <= 0 && b >= 0) || (a >= 0 && b <= 0) {
                let absb = abs(b)
                if absb < bestAbs {
                    bestAbs = absb
                    best = i
                }
            }
        }
        return best
    }

    private func computeRegions(for voices: [VoiceConfig]) {
        guard fileLengthSamples > 0 else { return }
        let pad = max(1, Int((crossfadeMs/1000.0)*sampleRate))
        var before = 0, after = 0
        var out: [UUID: LoopRegion] = [:]

        for (idx, v) in voices.enumerated() {
            let dur = max(64, Int(v.subdivision.seconds(bpm: bpm) * sampleRate))
            if idx == 0 {
                let off = Int(Double(before + dur) * widthScale)
                let start = max(0, anchorSample - off - dur)
                let snappedStart = nearestZeroCrossing(around: start)
                out[v.id] = .init(startSample: snappedStart, lengthSamples: dur)
                before += dur + pad
            } else if idx == 1 {
                let off = Int(Double(after) * widthScale)
                let start = min(fileLengthSamples - dur, anchorSample + off)
                let snappedStart = nearestZeroCrossing(around: start)
                out[v.id] = .init(startSample: snappedStart, lengthSamples: dur)
                after += dur + pad
            } else {
                let leftSide = idx % 2 == 0
                if leftSide {
                    let off = Int(Double(before + dur) * widthScale)
                    let start = max(0, anchorSample - off - dur)
                    let snappedStart = nearestZeroCrossing(around: start)
                    out[v.id] = .init(startSample: snappedStart, lengthSamples: dur)
                    before += dur + pad
                } else {
                    let off = Int(Double(after) * widthScale)
                    let start = min(fileLengthSamples - dur, anchorSample + off)
                    let snappedStart = nearestZeroCrossing(around: start)
                    out[v.id] = .init(startSample: snappedStart, lengthSamples: dur)
                    after += dur + pad
                }
            }
        }
        voiceRegions = out
    }

    // MARK: - Scheduling

    private func startAnyVoicesThatNeedIt() {
        guard let fileBuffer else { return }
        // schedule voices that have never been started
        
        for (id, v) in activeVoices {
            tombstonedVoices.remove(id) // voice is alive again; allow completions
            guard isStartedForVoice.contains(id) == false else { continue }
            guard let region = voiceRegions[id] else { continue }
            let n = player(for: id)
            // initial buffer
            let buf = buildBuffer(region: region, voice: v) ?? fileBuffer // fallback to whole file
            bufferCache[id] = buf
            n.stop()
            n.scheduleBuffer(buf, at: nil, options: [], completionHandler: { [weak self] in
                self?.scheduleNext(for: id)
            })
            n.play()
            // set initial instant params
            n.volume = v.mute ? 0 : v.volume
            n.pan = v.pan
            isStartedForVoice.insert(id)
        }
    }

    private func scheduleNext(for id: UUID) {
        // If this voice was stopped/removed, quietly bail.
        if tombstonedVoices.contains(id) { return }
        guard let v = activeVoices[id],
              let region = voiceRegions[id],
              let n = players[id] else { return }

        // Build or reuse buffer for next cycle
        let nextBuf: AVAudioPCMBuffer
        if needsRebuildNextCycle.contains(id) || bufferCache[id] == nil {
            nextBuf = buildBuffer(region: region, voice: v) ?? bufferCache[id] ?? fileBuffer!
            bufferCache[id] = nextBuf
            needsRebuildNextCycle.remove(id)
        } else {
            nextBuf = bufferCache[id]!
        }

        // Keep instant controls current
        n.volume = v.mute ? 0 : v.volume
        n.pan    = v.pan

        // Queue the next buffer; if the voice dies between now and callback, tombstone will stop recursion
        n.scheduleBuffer(nextBuf, at: nil, options: [], completionHandler: { [weak self] in
            self?.scheduleNext(for: id)
        })
    }


    // MARK: - Node plumbing

    private func player(for id: UUID) -> AVAudioPlayerNode {
        if let n = players[id] { return n }
        let n = AVAudioPlayerNode()
        engine.attach(n)
        engine.connect(n, to: engine.mainMixerNode, format: fileBuffer?.format)
        players[id] = n
        return n
    }

    // MARK: - Buffer builder (kept close to your working version’s intent)

    private func buildBuffer(region: LoopRegion, voice: VoiceConfig) -> AVAudioPCMBuffer? {
        guard let src = fileBuffer else { return nil }
        let start = max(0, min(region.startSample, fileLengthSamples - 1))
        let len   = max(1, min(region.lengthSamples, fileLengthSamples - start))
        let fmt   = src.format
        let out   = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(len))!
        out.frameLength = AVAudioFrameCount(len)

        // Source pointers
        let ch = Int(fmt.channelCount)
        guard let s0 = src.floatChannelData?[0] else { return nil }
        let s1 = ch > 1 ? src.floatChannelData?[1] : nil
        guard let d0 = out.floatChannelData?[0] else { return nil }
        let d1 = ch > 1 ? out.floatChannelData?[1] : nil

        // Helper to copy a range forward
        func copyForward(_ srcL: UnsafePointer<Float>, _ srcR: UnsafePointer<Float>?, dstL: UnsafeMutablePointer<Float>, dstR: UnsafeMutablePointer<Float>?, from: Int, count: Int) {
            for i in 0..<count {
                dstL[i] = srcL[from + i]
                if let sr = srcR, let dr = dstR { dr[i] = sr[from + i] }
            }
        }
        // Helper to copy a range reversed
        func copyReverse(_ srcL: UnsafePointer<Float>, _ srcR: UnsafePointer<Float>?, dstL: UnsafeMutablePointer<Float>, dstR: UnsafeMutablePointer<Float>?, from: Int, count: Int) {
            for i in 0..<count {
                dstL[i] = srcL[from + (count - 1 - i)]
                if let sr = srcR, let dr = dstR { dr[i] = sr[from + (count - 1 - i)] }
            }
        }

        switch voice.playback {
        case .forward:
            copyForward(s0, s1, dstL: d0, dstR: d1, from: start, count: len)
        case .reverse:
            copyReverse(s0, s1, dstL: d0, dstR: d1, from: start, count: len)
        case .pingPong:
            // half forward, half reverse (rounded)
            let a = len / 2
            let b = len - a
            copyForward(s0, s1, dstL: d0, dstR: d1, from: start, count: a)
            copyReverse(s0, s1, dstL: d0.advanced(by: a), dstR: d1?.advanced(by: a), from: start, count: b)
        case .reverseThenForward:
            let a = len / 2
            let b = len - a
            copyReverse(s0, s1, dstL: d0, dstR: d1, from: start, count: a)
            copyForward(s0, s1, dstL: d0.advanced(by: a), dstR: d1?.advanced(by: a), from: start, count: b)
        case .random:
            if Bool.random() {
                copyForward(s0, s1, dstL: d0, dstR: d1, from: start, count: len)
            } else {
                copyReverse(s0, s1, dstL: d0, dstR: d1, from: start, count: len)
            }
        }

        // Equal-power edge fades to reduce clicks
        let fadeSamples = max(1, Int(0.005 * sampleRate))
        for i in 0..<min(fadeSamples, len) {
            let t = Float(i) / Float(fadeSamples)
            let gin  = sin(0.5 * .pi * t)          // in: 0→1
            let gout = sin(0.5 * .pi * (1 - t))    // out: 1→0
            d0[i] *= gin; d0[len - 1 - i] *= gout
            d1?[i] *= gin; d1?[len - 1 - i] *= gout
        }

        return out
    }
}
