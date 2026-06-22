
import SwiftUI
import AVFoundation

struct ContentView: View {
    @StateObject private var engine = AudioEngineManager()
    @State private var voices: [VoiceConfig] = [VoiceConfig(index: 1),
                                                VoiceConfig(index: 2)]
    @State private var envelope: [Float] = []
    @State private var showingImporter = false
    @State private var clickingVoices: Set<UUID> = []

    var body: some View {
        VStack(spacing: 12) {
            headerBar

            if engine.fileBuffer == nil {
                Spacer()
                Text("Load a WAV or MP3 to begin").foregroundColor(.secondary)
                Button("Import Audio…") { showingImporter = true }
                    .keyboardShortcut("o", modifiers: .command)
                Spacer()
            } else {
                waveformSection
                globalControls
                voiceList
                HStack {
                    Button("Add Voice")    { addVoice() }.disabled(voices.count >= 10)
                    Button("Remove Last") { removeVoice() }.disabled(voices.isEmpty)
                    Spacer()
                    Button("Analyze Clicks") { analyzeClicks() }
                        .help("Submit click analysis to console")
                    Button("Stop") { engine.stopAll() }
                }
            }
        }
        .padding(14)
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: [.audio],
                      allowsMultipleSelection: false) { res in
            if case .success(let urls) = res, let u = urls.first { loadAudio(u) }
        }
        // Auto-propagate cycle-boundary changes
        .onChange(of: engine.anchorSample) { _ in engine.markCycleParamsChanged(voices: voices) }
        .onChange(of: engine.bpm)          { _ in engine.markCycleParamsChanged(voices: voices) }
        .onChange(of: engine.widthScale)   { _ in engine.markCycleParamsChanged(voices: voices) }
        .onChange(of: voices)              { _ in engine.markCycleParamsChanged(voices: voices) }
    }

    // == UI ==
    private var headerBar: some View {
        HStack {
            Text("Soundscape Looper").font(.title2).bold()
            Spacer()
            Button("Import Audio…") { showingImporter = true }
        }
    }

    private var waveformSection: some View {
        VStack(alignment: .leading) {
            let voiceRegions = voices.enumerated().compactMap { (index, voice) -> (id: UUID, region: LoopRegion, color: Color)? in
                guard let region = engine.region(for: voice.id) else { return nil }
                // Assign colors to voices
                let colors: [Color] = [.blue, .green, .orange, .purple, .pink, .red, .yellow, .mint, .cyan, .indigo]
                let color = colors[index % colors.count]
                return (voice.id, region, color)
            }
            
            let heads = voiceRegions.compactMap { item -> (UUID, Int, Color)? in
                if let s = engine.playheads[item.id] { return (item.id, s, item.color) }
                return nil
            }
            
            WaveformView(samples: envelope,
                         totalSamples: engine.fileLengthSamples,
                         sampleRate: engine.sampleRate,
                         anchorSample: $engine.anchorSample,
                         voiceRegions: voiceRegions.isEmpty ? nil : voiceRegions,
                         playheads: heads.isEmpty ? nil : heads)
                .frame(height: 200)
        }
    }

    private var globalControls: some View {
        GroupBox("Global") {
            HStack(spacing: 16) {
                // BPM
                HStack {
                    Text("BPM")
                    Stepper("", value: $engine.bpm, in: 40...300, step: 1)
                    Text("\(Int(engine.bpm))").monospacedDigit()
                }
                // Width
                HStack {
                    Text("Width")
                    Slider(value: $engine.widthScale, in: 0.5...4, step: 0.1)
                    Text(String(format: "%.1f", engine.widthScale)).monospacedDigit()
                }
                // Crossfade knob kept for parity (not used in this minimal version)
                HStack {
                    Text("Crossfade ms")
                    Slider(value: $engine.crossfadeMs, in: 0...50, step: 1)
                    Text("\(Int(engine.crossfadeMs))").monospacedDigit()
                }
                Spacer()
            }
        }
    }

    private var voiceList: some View {
        GroupBox("Voices") {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(Array(voices.enumerated()), id: \.element.id) { index, voice in
                        let colors: [Color] = [.blue, .green, .orange, .purple, .pink, .red, .yellow, .mint, .cyan, .indigo]
                        let color = colors[index % colors.count]
                        
                        VoiceStrip(voice: $voices[index], 
                                  bpm: engine.bpm, 
                                  color: color,
                                  isClicking: clickingVoices.contains(voice.id),
                                  onClickToggle: { toggleClickingVoice(voice.id) }) {
                            engine.liveAdjust(for: voice) // in case your row already calls back
                        }
                        // Ensure instant controls hit the node immediately
                        .onChange(of: voice.volume) { _ in engine.liveAdjust(for: voice) }
                        .onChange(of: voice.pan)    { _ in engine.liveAdjust(for: voice) }
                        .onChange(of: voice.mute)   { _ in applySoloMute() }
                        .onChange(of: voice.solo)   { _ in applySoloMute() }
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }

    // == helpers ==
    private func loadAudio(_ url: URL) {
        do {
            try engine.loadFile(url: url)
            if let buf = engine.fileBuffer {
                envelope = downsampleToEnvelope(buf, points: 1500)
            }
            engine.anchorSample = engine.fileLengthSamples / 2
            // kick off playback once; after that, param changes are boundary-safe
            engine.renderAndSchedule(voices: voices)
        } catch {
            print(error.localizedDescription)
        }
    }

    private func addVoice() { 
        voices.append(VoiceConfig(index: voices.count + 1))
        // Trigger engine update for new voice
        engine.markCycleParamsChanged(voices: voices)
        engine.renderAndSchedule(voices: voices)
    }
    
    private func removeVoice() {
        if let last = voices.popLast() { 
            engine.removePlayer(for: last.id) 
        }
    }
    
    private func applySoloMute() {
        let anySolo = voices.contains { $0.solo }
        for v in voices {
            var effective = v
            if anySolo {
                effective.mute = !v.solo
            }
            engine.liveAdjust(for: effective)
        }
    }
    
    private func toggleClickingVoice(_ id: UUID) {
        if clickingVoices.contains(id) {
            clickingVoices.remove(id)
        } else {
            clickingVoices.insert(id)
        }
    }
    
    private func analyzeClicks() {
        print("\n========== CLICK ANALYSIS REPORT ==========")
        print("Timestamp: \(Date())")
        print("BPM: \(engine.bpm), Width: \(engine.widthScale), Anchor: \(engine.anchorSample)")
        print("Sample rate: \(engine.sampleRate) Hz")
        print("Channel count: \(engine.channelCount)")
        print("File length: \(engine.fileLengthSamples) samples")
        print("Total voices: \(voices.count)")
        
        for voice in voices {
            let report = engine.analyzeClicksForVoice(voice.id, isClicking: clickingVoices.contains(voice.id))
            print(report)
            
            // Print effective cycle info
            if let region = engine.region(for: voice.id) {
                let cycleSamples = voice.playback == .pingPong || voice.playback == .reverseThenForward
                    ? region.lengthSamples * 2 : region.lengthSamples
                let cycleMs = Int(Double(cycleSamples) / engine.sampleRate * 1000)
                print("  Effective cycle: \(cycleMs)ms (\(cycleSamples) samples)")
                print("  Playback mode effect: \(voice.playback == .pingPong || voice.playback == .reverseThenForward ? "DOUBLED" : "NORMAL")")
            }
        }
        
        print("========== END REPORT ==========\n")
    }
}

// MARK: - Voice Strip (Vertical Mixer Channel)

fileprivate struct VoiceStrip: View {
    @Binding var voice: VoiceConfig
    var bpm: Double
    var color: Color
    var isClicking: Bool = false
    var onClickToggle: () -> Void = {}
    var onChanged: () -> Void
    
    var body: some View {
        VStack(alignment: .center, spacing: 6) {
            // Color indicator bar
            RoundedRectangle(cornerRadius: 4)
                .fill(color)
                .frame(height: 4)
            
            // Channel name
            Text(voice.name)
                .font(.caption)
                .bold()
            
            // Row 1: S / M / C
            HStack(spacing: 4) {
                Toggle("S", isOn: $voice.solo).toggleStyle(MixerButtonStyle(color: .yellow)).help("Solo")
                Toggle("M", isOn: $voice.mute).toggleStyle(MixerButtonStyle(color: .red)).help("Mute")
                Button(action: onClickToggle) {
                    Text("C").font(.caption).frame(width: 28, height: 28)
                        .background(isClicking ? Color.orange : Color.gray.opacity(0.3))
                        .foregroundColor(isClicking ? .white : .primary)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain).help("Mark as clicking")
            }
            
            Divider()
            
            // Row 2: Multiplier indicator + up/down control
            HStack(spacing: 4) {
                Text("×\(voice.subdivision.count)")
                    .font(.caption).monospacedDigit()
                    .frame(minWidth: 24)
                
                Stepper("", value: $voice.subdivision.count, in: 1...64)
                    .labelsHidden()
                    .scaleEffect(0.8)
            }
            
            // Row 3: Subdivision picker (note value)
            Picker("", selection: $voice.subdivision.kind) {
                ForEach(SubdivisionKind.allCases) { k in Text(k.rawValue).tag(k) }
            }
            .pickerStyle(.menu)
            .frame(width: 80)
            
            // Row 4: Modifier picker
            Picker("", selection: $voice.subdivision.modifier) {
                Text("Normal").tag(SubdivisionModifier.normal)
                Text("Dotted").tag(SubdivisionModifier.dotted)
                Text("Triplet").tag(SubdivisionModifier.triplet)
            }
            .pickerStyle(.menu)
            .frame(width: 80)
            
            // Loop mode (dropdown)
            Picker("", selection: $voice.playback) {
                Text("Forward").tag(PlaybackMode.forward)
                Text("Reverse").tag(PlaybackMode.reverse)
                Text("Ping-Pong").tag(PlaybackMode.pingPong)
                Text("Rev→Fwd").tag(PlaybackMode.reverseThenForward)
                Text("Random").tag(PlaybackMode.random)
            }
            .pickerStyle(.menu)
            .frame(width: 100)
            
            // Duration readout
            let seconds = voice.subdivision.seconds(bpm: bpm)
            Text(String(format: "%.0f ms", seconds * 1000))
                .font(.caption2).foregroundColor(.secondary)
            
            Divider()
            
            // Pan knob
            VStack(spacing: 2) {
                PanKnob(value: $voice.pan)
                    .frame(width: 50, height: 50)
                Text("Pan")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            // Volume fader
            VStack(spacing: 2) {
                VerticalSlider(value: $voice.volume, range: 0...1)
                    .frame(width: 40, height: 100)
                Text(String(format: "%.2f", voice.volume))
                    .font(.caption2)
                    .monospacedDigit()
                Text("Volume")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(8)
        .frame(width: 110)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
    
    func playbackIcon(for mode: PlaybackMode) -> String {
        switch mode {
        case .forward: return "arrow.right"
        case .reverse: return "arrow.left"
        case .pingPong: return "arrow.left.and.right"
        case .reverseThenForward: return "arrow.turn.up.right"
        case .random: return "shuffle"
        }
    }
}

// MARK: - Custom Controls

struct MixerButtonStyle: ToggleStyle {
    let color: Color
    
    func makeBody(configuration: Configuration) -> some View {
        Button(action: { configuration.isOn.toggle() }) {
            configuration.label
                .font(.caption)
                .frame(width: 28, height: 28)
                .background(configuration.isOn ? color : Color.gray.opacity(0.3))
                .foregroundColor(configuration.isOn ? .white : .primary)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
    }
}

struct VerticalSlider: View {
    @Binding var value: Float
    let range: ClosedRange<Float>

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                // Track (visual only)
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.2))
                    .allowsHitTesting(false)

                // Fill (visual only)
                let pct = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.accentColor)
                    .frame(height: max(0, geo.size.height * pct))
                    .allowsHitTesting(false)

                // Transparent hit layer to capture drags
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { g in
                                let y = min(max(0, g.location.y), geo.size.height)
                                let inv = 1 - (y / geo.size.height) // bottom=0, top=1
                                let newVal = Float(inv) * (range.upperBound - range.lowerBound) + range.lowerBound
                                value = min(max(newVal, range.lowerBound), range.upperBound)
                            }
                    )
            }
        }
    }
}

struct PanKnob: View {
    @Binding var value: Float
    @State private var isDragging = false
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Knob background
                Circle()
                    .fill(Color.gray.opacity(0.3))
                
                // Center indicator
                Circle()
                    .fill(Color.gray.opacity(0.5))
                    .frame(width: 4, height: 4)
                
                // Value indicator
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor)
                    .frame(width: 4, height: geometry.size.height * 0.4)
                    .offset(y: -geometry.size.height * 0.2)
                    .rotationEffect(.degrees(Double(value) * 135))
            }
            .overlay(
                // Gesture area
                Color.clear
                    .contentShape(Circle())
                    .gesture(
                        DragGesture()
                            .onChanged { drag in
                                let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
                                let angle = atan2(drag.location.x - center.x, center.y - drag.location.y)
                                let normalizedAngle = angle / (.pi * 3/4) // ±135 degrees range
                                value = Float(max(-1, min(1, normalizedAngle)))
                                isDragging = true
                            }
                            .onEnded { _ in
                                isDragging = false
                            }
                    )
                    .onTapGesture(count: 2) {
                        // Double-tap to center
                        withAnimation(.easeOut(duration: 0.2)) {
                            value = 0
                        }
                    }
            )
            .scaleEffect(isDragging ? 1.1 : 1.0)
            .animation(.easeOut(duration: 0.1), value: isDragging)
        }
    }
}
