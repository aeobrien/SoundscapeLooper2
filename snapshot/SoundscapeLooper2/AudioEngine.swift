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
    
    // Audio processing options
    @Published public var safetyLimiterEnabled: Bool = false
    @Published public var safetyLimiterDrive: Float = 1.0 // 1.0 = unity, >1 adds colour
    @Published public var superSafeLoops: Bool = false // Extra-long crossfades for difficult material

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
    
    // Grid sync state - for quantized start without glitching
    private var nextGridTime: AVAudioTime? = nil
    private var voiceStartTimes: [UUID: AVAudioTime] = [:]

    public init() {
        // macOS: no AVAudioSession needed
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)
        try? engine.start()
        // Increased refresh rate for better sync
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0/120.0, repeats: true) { [weak self] _ in
            self?.updatePlayheads()
        }
    }

    // MARK: - Transport helpers
    
    // Grid quantum calculation (1/16 note)
    private func gridQuantumFrames(bpm: Double) -> Int {
        let framesPerBeat = Int(sampleRate * 60.0 / bpm)
        return max(1, framesPerBeat / 16) // 1/16 note grid
    }
    
    // MARK: - Public API
    
    // Enhanced click analysis for debugging
    func analyzeClicksForVoice(_ voiceId: UUID, isClicking: Bool) -> String {
        guard let region = voiceRegions[voiceId],
              let buffer = fileBuffer,
              let voice = activeVoices[voiceId],
              let ch0 = buffer.floatChannelData?[0] else {
            return "Unable to analyze: missing data"
        }
        
        let start = region.startSample
        let end = start + region.lengthSamples - 1
        let analyzeWindow = 128 // samples to analyze at boundaries
        
        // Zero crossing distances
        let startZ = nearestZeroCrossing(around: start, search: 256)
        let endZ = nearestZeroCrossing(around: end, search: 256)
        let startZDist = start - startZ
        let endZDist = end - endZ
        
        // If the end is still >128 samples from a ZC, flag for auto-repair next render
        if abs(endZDist) > 128 {
            crossfadeMs = max(crossfadeMs, 50)             // longer splice
        }
        
        // Slopes
        let startSlope = ch0[min(start+1, end)] - ch0[start]
        let endSlope = ch0[end] - ch0[max(start, end-1)]
        
        // Analyze start of loop
        var startInfo = "Start analysis (sample \(start)):\n"
        let startWindow = min(analyzeWindow, region.lengthSamples)
        var startMax: Float = 0
        var startRMS: Float = 0
        for i in 0..<startWindow {
            let val = ch0[start + i]
            startMax = max(startMax, abs(val))
            startRMS += val * val
        }
        startRMS = sqrt(startRMS / Float(startWindow))
        let crestStart = startMax / max(1e-7, startRMS)
        
        func zcStr(_ d: Int) -> String { d == 0 ? "0" : "\(abs(d)) (\(d < 0 ? "before" : "after"))" }
        startInfo += "  First sample: \(ch0[start])\n"
        startInfo += "  Max amplitude (first \(startWindow) samples): \(startMax)\n"
        startInfo += "  RMS (first \(startWindow) samples): \(startRMS)\n"
        startInfo += "  Crest factor: \(crestStart)\n"
        startInfo += "  Slope: \(startSlope)\n"
        startInfo += "  Zero-crossing distance: \(zcStr(startZDist)) samples\n"
        
        // Analyze end of loop
        var endInfo = "End analysis (sample \(end)):\n"
        let endWindowStart = max(start, end - analyzeWindow + 1)
        let endWindow = end - endWindowStart + 1
        var endMax: Float = 0
        var endRMS: Float = 0
        for i in 0..<endWindow {
            let val = ch0[endWindowStart + i]
            endMax = max(endMax, abs(val))
            endRMS += val * val
        }
        endRMS = sqrt(endRMS / Float(endWindow))
        let crestEnd = endMax / max(1e-7, endRMS)
        
        endInfo += "  Last sample: \(ch0[end])\n"
        endInfo += "  Max amplitude (last \(endWindow) samples): \(endMax)\n"
        endInfo += "  RMS (last \(endWindow) samples): \(endRMS)\n"
        endInfo += "  Crest factor: \(crestEnd)\n"
        endInfo += "  Slope: \(endSlope)\n"
        endInfo += "  Zero-crossing distance: \(zcStr(endZDist)) samples\n"
        
        // Tail↔Head correlation
        let w = min(analyzeWindow, region.lengthSamples/4)
        var dot: Float = 0, a2: Float = 0, b2: Float = 0
        for i in 0..<w {
            let a = ch0[end - w + 1 + i]
            let b = ch0[start + i]
            dot += a*b; a2 += a*a; b2 += b*b
        }
        let corr = (a2 > 0 && b2 > 0) ? (dot / sqrt(a2*b2)) : 0
        
        // Spectral centroid proxy
        func centroid(_ base: Int, _ count: Int) -> Float {
            var num: Float = 0, den: Float = 0
            for i in 0..<count {
                let v = abs(ch0[base + i])
                num += Float(i) * v; den += v
            }
            return den > 0 ? num/den : 0
        }
        let headCent = centroid(start, w)
        let tailCent = centroid(end - w + 1, w)
        
        // Cycle length info
        let cycleSamples = voice.playback == .pingPong || voice.playback == .reverseThenForward 
            ? region.lengthSamples * 2 : region.lengthSamples
        let cycleMs = Int(Double(cycleSamples) / sampleRate * 1000)
        
        // Voice info
        let voiceInfo = """
        Voice: \(voice.name) (ID: \(voiceId))
        Clicking: \(isClicking ? "YES" : "NO")
        Subdivision: \(voice.subdivision.kind.rawValue) \(voice.subdivision.modifier.rawValue) ×\(voice.subdivision.count)
        Duration: \(Int(voice.subdivision.seconds(bpm: bpm) * 1000))ms (\(region.lengthSamples) samples)
        Effective cycle: \(cycleMs)ms (\(cycleSamples) samples)
        Playback: \(voice.playback.rawValue)
        Volume: \(voice.volume)
        Anchor: \(anchorSample)
        """
        
        // Auto-increase crossfade when correlation is low
        if corr < 0.3 && crossfadeMs < 30 { 
            crossfadeMs = 30  // This will trigger rebuild with longer fade
        }
        
        let correlationInfo = """
        
        Boundary correlation:
          Tail↔Head correlation: \(corr)
          Head centroid: \(headCent)
          Tail centroid: \(tailCent)
        """
        
        // Likely causes
        let highEnergySeam = max(startRMS, endRMS) > 0.06
        var causes: [String] = []
        if abs(startSlope) > 0.25 || abs(endSlope) > 0.25 { causes.append("steep slope at boundary") }
        if corr < 0.4 { causes.append("tail↔head mismatch") }
        if (abs(startZDist) > 32 || abs(endZDist) > 32) && corr < 0.60 { 
            causes.append("off zero-crossing") 
        }
        if crestStart > 8 || crestEnd > 8 { causes.append("peaky transient at boundary") }
        if highEnergySeam { causes.append("high-energy boundary (increase crossfade)") }
        
        let causesInfo = causes.isEmpty ? "LIKELY CLICK CAUSES: None detected" 
            : "LIKELY CLICK CAUSES: \(causes.joined(separator: ", "))"
        
        // Suggested fix
        let suggestion: String = {
            if causes.contains(where: { $0.contains("off zero-crossing") }) { 
                return "Try moving anchor slightly or enable tighter end micro-alignment (±240s) and re-snap." 
            }
            if causes.contains(where: { $0.contains("tail↔head mismatch") }) { 
                return "Increase crossfade (20–40 ms) or shift end by +/− 80–160 samples via micro-alignment." 
            }
            if causes.contains(where: { $0.contains("steep slope") }) { 
                return "Shorten region by ~32 samples to a flatter segment or reduce high-freq with gentle LPF." 
            }
            if causes.contains(where: { $0.contains("high-energy") }) { 
                return "Raise adaptive crossfade ceiling to ~40 ms for this voice." 
            }
            return "Seam looks OK. If you still hear a tick, audition with mono sum; transients can mask subtle zips."
        }()
        
        return """
=== CLICK ANALYSIS REPORT ===
\(voiceInfo)

\(startInfo)
\(endInfo)
\(correlationInfo)

\(causesInfo)
Suggested fix: \(suggestion)

Effective cycle: \(cycleMs)ms (\(cycleSamples) samples)
Playback mode effect: \(voice.playback == .pingPong || voice.playback == .reverseThenForward ? "DOUBLED (2× length)" : "NORMAL")
"""
    }

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
        // Reset grid time to resync all voices on next cycle
        nextGridTime = nil
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
        // Subtract hardware/output latency from mapping
        let hwLatencySec = engine.outputNode.outputPresentationLatency
        let latencySamples = Int(hwLatencySec * sampleRate)
        
        for (id, node) in players {
            guard let v = activeVoices[id],
                  let region = voiceRegions[id],
                  node.isPlaying,
                  let nodeTime = node.lastRenderTime,
                  nodeTime.isSampleTimeValid,
                  let ptime = node.playerTime(forNodeTime: nodeTime) else { continue }
            
            // Use adjusted sampleTime for position
            let rawST = Int(ptime.sampleTime)
            let adjST = max(0, rawST - latencySamples)
            
            // Map buffer position to actual file position based on playback mode
            let posInCycle: Int
            let cycleLen: Int
            let filePos: Int
            
            switch v.playback {
            case .pingPong:
                // Full forward + full reverse (2x length cycle)
                cycleLen = region.lengthSamples * 2
                posInCycle = adjST % cycleLen
                if posInCycle < region.lengthSamples {
                    // Forward phase
                    filePos = region.startSample + posInCycle
                } else {
                    // Reverse phase
                    let revPos = posInCycle - region.lengthSamples
                    filePos = region.startSample + (region.lengthSamples - 1 - revPos)
                }
                
            case .reverseThenForward:
                // Full reverse + full forward (2x length cycle)
                cycleLen = region.lengthSamples * 2
                posInCycle = adjST % cycleLen
                if posInCycle < region.lengthSamples {
                    // Reverse phase
                    filePos = region.startSample + (region.lengthSamples - 1 - posInCycle)
                } else {
                    // Forward phase
                    filePos = region.startSample + (posInCycle - region.lengthSamples)
                }
                
            case .forward:
                cycleLen = region.lengthSamples
                posInCycle = adjST % cycleLen
                filePos = region.startSample + posInCycle
                
            case .reverse:
                cycleLen = region.lengthSamples
                posInCycle = adjST % cycleLen
                filePos = region.startSample + (region.lengthSamples - 1 - posInCycle)
                
            case .random:
                // For random, just use forward mapping as we can't predict
                cycleLen = region.lengthSamples
                posInCycle = adjST % cycleLen
                filePos = region.startSample + posInCycle
            }
            
            playheads[id] = filePos
        }
    }
    
    // Try small ±window shift around 'end' to best match head content
    private func bestEndForSeam(start: Int, length: Int, search: Int = 1024) -> Int {
        guard let buf = fileBuffer, let s0 = buf.floatChannelData?[0] else { return start + length - 1 }
        let endNom = start + length - 1
        let lo = max(start + 64, endNom - search) // keep some room for window
        let hi = min(fileLengthSamples - 2, endNom + search)
        // Compare last W samples of tail to first W of head
        let W = min(256, length / 4)
        var bestEnd = endNom
        var bestScore: Float = -.greatestFiniteMagnitude
        // Preload head slice
        var head = [Float](repeating: 0, count: W)
        for i in 0..<W { head[i] = s0[start + i] }
        // Head stats
        var headMag: Float = 0; for i in 0..<W { headMag += head[i]*head[i] }
        headMag = max(headMag, 1e-9)
        for e in lo...hi {
            // ensure we have W samples ending at e
            let tailBase = e - W + 1
            if tailBase <= start { continue }
            var dot: Float = 0, tailMag: Float = 0
            for k in 0..<W {
                let a = s0[tailBase + k]
                let b = head[k]
                dot += a*b; tailMag += a*a
            }
            let score = dot / sqrt(tailMag * headMag) // correlation
            // Down-weight if tail slope sign differs from head slope sign
            let slopeHead = s0[start + 1] - s0[start]
            let slopeTail = s0[e] - s0[e-1]
            let sameSign  = (slopeHead >= 0 && slopeTail >= 0) || (slopeHead <= 0 && slopeTail <= 0)
            let bonus: Float = sameSign ? 0.02 : -0.02          // tiny nudge
            let zcDist = abs(s0[e])                         // closeness to zero
            let zcPenalty = zcDist * 0.05                   // 1.0 sample ≈ −0.05 score
            let farZC: Float = abs(zcDist) > 64 ? -0.05 : 0   // push search toward true zero
            let totalScore = score + bonus - zcPenalty + farZC
            if totalScore > bestScore { bestScore = totalScore; bestEnd = e }
        }
        // Nudge to nearest zero-crossing with matched slope sign
        let snap = nearestZeroCrossing(around: bestEnd, search: 256)
        return snap
    }
    
    private func nearestZeroCrossing(around sample: Int, search: Int = 2048) -> Int {
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

        // Slope helper
        func slope(at i: Int, ch: UnsafePointer<Float>) -> Float {
            let a = ch[max(0, i-1)]
            let b = ch[min(fileLengthSamples-1, i)]
            return b - a
        }
        
        for (idx, v) in voices.enumerated() {
            let dur = max(64, Int(v.subdivision.seconds(bpm: bpm) * sampleRate))
            if idx == 0 {
                let off = Int(Double(before + dur) * widthScale)
                let start = max(0, anchorSample - off - dur)
                let snappedStart = nearestZeroCrossing(around: start)
                // Use micro-alignment for best seam
                var snappedLen = dur
                let bestEnd = bestEndForSeam(start: snappedStart, length: dur, search: 240)
                if bestEnd > snappedStart + 64 { snappedLen = bestEnd - snappedStart + 1 }
                out[v.id] = .init(startSample: snappedStart, lengthSamples: snappedLen)
                before += dur + pad
            } else if idx == 1 {
                let off = Int(Double(after) * widthScale)
                let start = min(fileLengthSamples - dur, anchorSample + off)
                let snappedStart = nearestZeroCrossing(around: start)
                // Use micro-alignment for best seam
                var snappedLen = dur
                let bestEnd = bestEndForSeam(start: snappedStart, length: dur, search: 240)
                if bestEnd > snappedStart + 64 { snappedLen = bestEnd - snappedStart + 1 }
                out[v.id] = .init(startSample: snappedStart, lengthSamples: snappedLen)
                after += dur + pad
            } else {
                let leftSide = idx % 2 == 0
                if leftSide {
                    let off = Int(Double(before + dur) * widthScale)
                    let start = max(0, anchorSample - off - dur)
                    let snappedStart = nearestZeroCrossing(around: start)
                    // Use micro-alignment for best seam with wider search
                    var snappedLen = dur
                    let bestEnd = bestEndForSeam(start: snappedStart, length: dur, search: 512) // wider search
                    if bestEnd > snappedStart + 32 { snappedLen = bestEnd - snappedStart + 1 } // keep at least 0.67ms
                    out[v.id] = .init(startSample: snappedStart, lengthSamples: snappedLen)
                    before += dur + pad
                } else {
                    let off = Int(Double(after) * widthScale)
                    let start = min(fileLengthSamples - dur, anchorSample + off)
                    let snappedStart = nearestZeroCrossing(around: start)
                    // Use micro-alignment for best seam with wider search
                    var snappedLen = dur
                    let bestEnd = bestEndForSeam(start: snappedStart, length: dur, search: 512) // wider search
                    if bestEnd > snappedStart + 32 { snappedLen = bestEnd - snappedStart + 1 } // keep at least 0.67ms
                    out[v.id] = .init(startSample: snappedStart, lengthSamples: snappedLen)
                    after += dur + pad
                }
            }
        }
        voiceRegions = out
    }

    // MARK: - Scheduling

    private func startAnyVoicesThatNeedIt() {
        guard let fileBuffer else { return }
        
        // Calculate next grid position for synchronized start
        var startTime: AVAudioTime? = nil
        
        // Only calculate grid time once for all voices
        if nextGridTime == nil {
            if let nodeTime = engine.outputNode.lastRenderTime {
                let quantum = gridQuantumFrames(bpm: bpm)
                let currentFrame = nodeTime.sampleTime
                let nextGridFrame = ((currentFrame / AVAudioFramePosition(quantum)) + 1) * AVAudioFramePosition(quantum)
                startTime = AVAudioTime(sampleTime: nextGridFrame, atRate: sampleRate)
                nextGridTime = startTime
            }
        } else {
            startTime = nextGridTime
        }
        
        // Start all voices at the same grid position
        for (id, v) in activeVoices {
            tombstonedVoices.remove(id) // voice is alive again; allow completions
            guard isStartedForVoice.contains(id) == false else { continue }
            guard let region = voiceRegions[id] else { continue }
            let n = player(for: id)
            
            // Build initial buffer
            let buf = buildBuffer(region: region, voice: v) ?? fileBuffer // fallback to whole file
            bufferCache[id] = buf
            
            // Stop any existing playback
            n.stop()
            
            // Schedule at grid time (or immediately if no grid time)
            n.scheduleBuffer(buf, at: startTime, options: [], completionHandler: { [weak self] in
                self?.scheduleNext(for: id)
            })
            n.play()
            
            // Store start time for this voice
            if let st = startTime {
                voiceStartTimes[id] = st
            }
            
            // Set initial instant params
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

        // Queue the next buffer immediately for seamless looping
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

    // MARK: - Buffer builder with circular splice and proper ping-pong

    private func buildBuffer(region: LoopRegion, voice: VoiceConfig) -> AVAudioPCMBuffer? {
        guard let src = fileBuffer else { return nil }
        let start = max(0, min(region.startSample, fileLengthSamples - 1))
        let len   = max(1, min(region.lengthSamples, fileLengthSamples - start))
        let fmt   = src.format
        
        // Source pointers
        let ch = Int(fmt.channelCount)
        guard let s0 = src.floatChannelData?[0] else { return nil }
        let s1 = ch > 1 ? src.floatChannelData?[1] : nil

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
        
        // Post-processing function for DC removal, HPF, limiter, and circular splice
        func postProcess(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
            let bufLen = Int(buffer.frameLength)
            guard let d0 = buffer.floatChannelData?[0] else { return buffer }
            let d1 = ch > 1 ? buffer.floatChannelData?[1] : nil
            
            // DC removal first
            var mean0: Float = 0, mean1: Float = 0
            for i in 0..<bufLen { mean0 += d0[i]; mean1 += d1?[i] ?? 0 }
            mean0 /= Float(bufLen); mean1 /= Float(bufLen)
            for i in 0..<bufLen { d0[i] -= mean0; if let _ = d1 { d1![i] -= mean1 } }
            
            // Canonical 1-pole HPF (stable)
            let sr = Float(sampleRate)
            let fc: Float = 20.0
            let k = tanf(Float.pi * fc / sr)
            let a = (1 - k) / (1 + k)
            
            var yL: Float = 0, xL1: Float = 0
            var yR: Float = 0, xR1: Float = 0
            for i in 0..<bufLen {
                let xL = d0[i]
                let outL = a * (yL + xL - xL1)
                d0[i] = outL; yL = outL; xL1 = xL
                if let d1 = d1 {
                    let xR = d1[i]
                    let outR = a * (yR + xR - xR1)
                    d1[i] = outR; yR = outR; xR1 = xR
                }
            }
            
            // Optional safety limiter
            if safetyLimiterEnabled {
                let drive = max(1.0, safetyLimiterDrive)
                for i in 0..<bufLen {
                    d0[i] = tanh(d0[i] * drive)
                    if let d1 = d1 { d1[i] = tanh(d1[i] * drive) }
                }
            }
            
            // Detect if this is a doubled buffer (ping-pong, reverse-then-forward)
            let isDouble = bufLen >= 2 && buffer.frameLength % 2 == 0
            
            // Adaptive circular splice length (content-aware crossfade)
            // Only apply to non-doubled buffers (doubled buffers get mid-seam instead)
            if !isDouble {
                // Estimate roughness at seam: RMS of head/tail windows
                let W = min(256, bufLen/4)
                func rms(_ p: UnsafePointer<Float>, _ base: Int, _ count: Int) -> Float {
                    var acc: Float = 0; for i in 0..<count { let v = p[base + i]; acc += v*v }
                    return sqrt(acc / Float(max(1, count)))
                }
                let headRMS = rms(d0, 0, W)
                let tailRMS = rms(d0, max(0, bufLen - W), W)
                let rough = max(headRMS, tailRMS)
                
                // Quick head↔tail correlation (same W)
                var dot: Float = 0, a2: Float = 0, b2: Float = 0
                for k in 0..<W { let a = d0[bufLen-W+k]; let b = d0[k]; dot += a*b; a2 += a*a; b2 += b*b }
                let corr = (a2 > 0 && b2 > 0) ? dot / sqrt(a2*b2) : 0
                
                // Map roughness → crossfade (5–40 ms), plus user override
                let minMs: Float = 5, maxMs: Float = 40
                let baseMs = Float(crossfadeMs > 0 ? crossfadeMs : 10)
                var targetMs = min(max(baseMs, minMs + (maxMs - minMs) * min(1, rough / 0.1)), maxMs)
                if corr < 0.40 { targetMs = max(targetMs, 40) }      // stubborn mismatch → longer fade
                if superSafeLoops && corr < 0 { targetMs = 80 }      // super-safe mode for phase-flipped
                else if corr < 0 { targetMs = 60 }                    // normal phase-flipped → 60 ms safety net
                
                // If tail↔head RMS ratio > 2 or corr < 0.20  →  very soft 80 ms splice
                let tailHeadRatio = tailRMS > 0 ? headRMS / tailRMS : 1
                if tailHeadRatio > 2.0 || corr < 0.20 {
                    targetMs = max(targetMs, 80)
                }
                let fade = max(64, Int(targetMs * 0.001 * Float(sampleRate)))
                let fN = min(fade, bufLen / 3)
                
                if fN > 1 {
                    // Apply truly symmetric equal-power crossfade between tail and head
                    for i in 0..<fN {
                        let t = Float(i) / Float(fN - 1)
                        let wTail = cosf(t * .pi * 0.5)           // 1 → 0
                        let wHead = sinf(t * .pi * 0.5)           // 0 → 1
                        let tailIdx = bufLen - fN + i             // last  fN
                        let headIdx = i                           // first fN

                        // --- left
                        let tailL = d0[tailIdx], headL = d0[headIdx]
                        d0[tailIdx] = tailL * wTail + headL * wHead
                        d0[headIdx] = headL * wTail + tailL * wHead

                        // --- right (if stereo)
                        if let d1 = d1 {
                            let tailR = d1[tailIdx], headR = d1[headIdx]
                            d1[tailIdx] = tailR * wTail + headR * wHead
                            d1[headIdx] = headR * wTail + tailR * wHead
                        }
                    }
                    
                    // Feather the first 8 samples after the head-fade so we don't step back to raw head
                    let feather = min(8, fN)
                    for i in 0..<feather {
                        let g = Float(i + 1) / Float(feather + 1)          // 0→1 rise
                        d0[feather + i] *= g
                        if let d1 = d1 { d1[feather + i] *= g }
                    }
                    
                    // Optional boundary LPF for hot seams
                    let highEnergySeam = rough > 0.08
                    if highEnergySeam {
                        let K = min(96, fN/2)
                        // Simple moving-average as a cheap LPF on last K samples
                        var acc: Float = 0
                        for i in (bufLen - K)..<bufLen {
                            acc = 0
                            let win = min(8, i - (bufLen - K) + 1)
                            for j in 0..<win { acc += d0[i - j] }
                            d0[i] = acc / Float(win)
                            if let d1 = d1 {
                                acc = 0
                                for j in 0..<win { acc += d1[i - j] }
                                d1[i] = acc / Float(win)
                            }
                        }
                    }
                    
                    // Match RMS level as well as shape to prevent quiet→loud step
                    let W2 = min(256, bufLen/4)
                    func rms2(_ p: UnsafePointer<Float>, _ base: Int) -> Float {
                        var acc: Float = 0; for i in 0..<W2 { let v = p[base+i]; acc += v*v }
                        return sqrt(acc / Float(W2))
                    }
                    let rmsHead = rms2(d0, 0)
                    let rmsTail = rms2(d0, bufLen-W2)
                    if rmsTail > 0 && rmsHead > 0 {
                        let g = rmsHead / rmsTail                         // gain to apply to tail
                        for i in 0..<W2 {
                            d0[bufLen-W2+i] *= g
                            if let d1=d1 { d1[bufLen-W2+i] *= g }
                        }
                    }
                }
            }
            
            // Mid-seam crossfade for doubled buffers (ping-pong, reverse-then-forward)
            if isDouble {
                let half = bufLen / 2
                let defaultFade = max(1, Int(crossfadeMs * 0.001 * sampleRate))
                let fN2 = min(defaultFade, half/4) // use crossfadeMs, but cap sensibly
                if fN2 > 0 {
                    for i in 0..<fN2 {
                        let t = Float(i) / Float(max(1, fN2 - 1))
                        let wA = sqrtf(1.0 - t)
                        let wB = sqrtf(t)
                        // L
                        let aL = d0[half - fN2 + i]
                        let bL = d0[half + i]
                        d0[half - fN2 + i] = aL * wA + bL * wB
                        d0[half + i] = bL * wA + aL * wB
                        // R
                        if let d1 = d1 {
                            let aR = d1[half - fN2 + i]
                            let bR = d1[half + i]
                            d1[half - fN2 + i] = aR * wA + bR * wB
                            d1[half + i] = bR * wA + aR * wB
                        }
                    }
                }
            }
            
            // De-zipper: enforce slope continuity across wrap (spread over 2 samples)
            if bufLen > 4 && !isDouble {
                let wrapL0 = d0[bufLen-2], wrapL1 = d0[bufLen-1]
                let headL0 = d0[0],       headL1 = d0[1]
                let tailSlopeL = wrapL1 - wrapL0
                let headSlopeL = headL1 - headL0
                let fixL = 0.5 * (tailSlopeL - headSlopeL)
                d0[1] += fixL * 0.66     // spread ⅔ into s[1]
                if bufLen > 2 { d0[2] += fixL * 0.34 }    // …and ⅓ into s[2]
                if let d1 = d1 {
                    let w0 = d1[bufLen-2], w1 = d1[bufLen-1]
                    let h0 = d1[0],        h1 = d1[1]
                    let tS = w1 - w0, hS = h1 - h0
                    let fixR = 0.5 * (tS - hS)
                    d1[1] += fixR * 0.66
                    if bufLen > 2 { d1[2] += fixR * 0.34 }
                }
            }
            
            return buffer
        }

        // Build appropriate buffer based on playback mode
        switch voice.playback {
        case .forward:
            let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(len))!
            out.frameLength = AVAudioFrameCount(len)
            guard let d0 = out.floatChannelData?[0] else { return nil }
            let d1 = ch > 1 ? out.floatChannelData?[1] : nil
            copyForward(s0, s1, dstL: d0, dstR: d1, from: start, count: len)
            return postProcess(out)
            
        case .reverse:
            let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(len))!
            out.frameLength = AVAudioFrameCount(len)
            guard let d0 = out.floatChannelData?[0] else { return nil }
            let d1 = ch > 1 ? out.floatChannelData?[1] : nil
            copyReverse(s0, s1, dstL: d0, dstR: d1, from: start, count: len)
            return postProcess(out)
            
        case .pingPong:
            // Full forward + full reverse (2x length)
            let cycle = len * 2
            let out2 = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(cycle))!
            out2.frameLength = AVAudioFrameCount(cycle)
            guard let d0b = out2.floatChannelData?[0] else { return nil }
            let d1b = ch > 1 ? out2.floatChannelData?[1] : nil
            // forward
            copyForward(s0, s1, dstL: d0b, dstR: d1b, from: start, count: len)
            // reverse immediately after
            copyReverse(s0, s1, dstL: d0b.advanced(by: len), dstR: d1b?.advanced(by: len), from: start, count: len)
            return postProcess(out2)
            
        case .reverseThenForward:
            // Full reverse + full forward (2x length)
            let cycle = len * 2
            let out2 = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(cycle))!
            out2.frameLength = AVAudioFrameCount(cycle)
            guard let d0b = out2.floatChannelData?[0] else { return nil }
            let d1b = ch > 1 ? out2.floatChannelData?[1] : nil
            // reverse first
            copyReverse(s0, s1, dstL: d0b, dstR: d1b, from: start, count: len)
            // forward after
            copyForward(s0, s1, dstL: d0b.advanced(by: len), dstR: d1b?.advanced(by: len), from: start, count: len)
            return postProcess(out2)
            
        case .random:
            let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(len))!
            out.frameLength = AVAudioFrameCount(len)
            guard let d0 = out.floatChannelData?[0] else { return nil }
            let d1 = ch > 1 ? out.floatChannelData?[1] : nil
            if Bool.random() {
                copyForward(s0, s1, dstL: d0, dstR: d1, from: start, count: len)
            } else {
                copyReverse(s0, s1, dstL: d0, dstR: d1, from: start, count: len)
            }
            return postProcess(out)
        }
    }
}
