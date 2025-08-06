import SwiftUI
import AVFoundation
import Accelerate

/// Enhanced waveform renderer with zoom, anchor marker, and voice region highlights
struct WaveformView: View {
    let samples: [Float]          // downsampled envelope [-1..1]
    let totalSamples: Int         // total samples in file
    let sampleRate: Double
    @Binding var anchorSample: Int
    let voiceRegions: [(id: UUID, region: LoopRegion, color: Color)]? // optional voice regions to highlight
    let playheads: [(id: UUID, sample: Int, color: Color)]?
    
    @State private var isDragging: Bool = false
    @State private var zoomLevel: Double = 1.0
    @State private var scrollOffset: Double = 0.0
    @State private var lastAnchorRatio: CGFloat = 0.5
    
    var body: some View {
        VStack(spacing: 8) {
            // Zoom controls
            HStack {
                Text("Zoom:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Slider(value: $zoomLevel, in: 1...10)
                    .frame(width: 200)
                Text(String(format: "%.1fx", zoomLevel))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundColor(.secondary)
                    .frame(width: 40)
                Button("Reset") {
                    withAnimation {
                        zoomLevel = 1.0
                        centerOnAnchor()
                    }
                }
                .font(.caption)
                .buttonStyle(.plain)
                Spacer()
            }
            
            GeometryReader { geo in
                let effectiveWidth = geo.size.width * zoomLevel
                
                ScrollViewReader { scrollProxy in
                    ScrollView(.horizontal, showsIndicators: true) {
                        ZStack(alignment: .topLeading) {
                            
                            // Voice region highlights
                            if let regions = voiceRegions {
                                ForEach(regions, id: \.id) { voice in
                                    let startX = xForSample(voice.region.startSample, width: effectiveWidth)
                                    let endX = xForSample(voice.region.startSample + voice.region.lengthSamples, width: effectiveWidth)
                                    Rectangle()
                                        .fill(voice.color.opacity(0.2))
                                        .frame(width: endX - startX, height: geo.size.height)
                                        .position(x: (startX + endX) / 2, y: geo.size.height / 2)
                                }
                            }
                            
                            // Waveform path
                            Canvas { ctx, size in
                                let midY = size.height / 2
                                let count = samples.count
                                guard count > 1 else { return }
                                
                                // Main waveform
                                var path = Path()
                                for (i, v) in samples.enumerated() {
                                    let x = CGFloat(i) / CGFloat(count - 1) * effectiveWidth
                                    let y = midY - CGFloat(v) * (midY - 2)
                                    if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                                    else { path.addLine(to: CGPoint(x: x, y: y)) }
                                }
                                ctx.stroke(path, with: .color(.primary.opacity(0.6)), lineWidth: 1)
                                
                                // Center line
                                ctx.stroke(Path { p in
                                    p.move(to: CGPoint(x: 0, y: midY))
                                    p.addLine(to: CGPoint(x: effectiveWidth, y: midY))
                                }, with: .color(.secondary.opacity(0.3)), lineWidth: 0.5)
                            }
                            .frame(width: effectiveWidth, height: geo.size.height)
                            .background(Color.black.opacity(0.03))
                            
                            // Anchor marker
                            let xAnchor = xForSample(anchorSample, width: effectiveWidth)
                            Rectangle()
                                .fill(Color.accentColor)
                                .frame(width: 2, height: geo.size.height)
                                .position(x: xAnchor, y: geo.size.height/2)
                                .id("anchor") // For auto-scrolling
                            
                            // Playhead lines
                            if let heads = playheads {
                                ForEach(heads, id: \.id) { h in
                                    let x = xForSample(h.sample, width: effectiveWidth)
                                    Rectangle()
                                        .fill(h.color.opacity(0.9))
                                        .frame(width: 1, height: geo.size.height)
                                        .position(x: x, y: geo.size.height / 2)
                                }
                            }
                            
                            // Draggable handle
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.accentColor)
                                .frame(width: 12, height: 30)
                                .position(x: xAnchor, y: 15)
                                .gesture(
                                    DragGesture(minimumDistance: 0)
                                        .onChanged { g in
                                            isDragging = true
                                            let x = min(max(0, g.location.x), effectiveWidth)
                                            anchorSample = sampleForX(x, width: effectiveWidth)
                                        }
                                        .onEnded { _ in isDragging = false }
                                )
                        }
                        .frame(width: effectiveWidth, height: geo.size.height)
                        .contentShape(Rectangle())
                        .onTapGesture { location in
                            // Click to set anchor
                            let x = min(max(0, location.x), effectiveWidth)
                            anchorSample = sampleForX(x, width: effectiveWidth)
                        }
                    }
                    .onAppear {
                        lastAnchorRatio = CGFloat(anchorSample) / CGFloat(max(1, totalSamples - 1))
                        centerOnAnchor(proxy: scrollProxy, width: geo.size.width)
                    }
                    .onChange(of: anchorSample) { _ in
                        lastAnchorRatio = CGFloat(anchorSample) / CGFloat(max(1, totalSamples - 1))
                    }
                    .onChange(of: zoomLevel) { _ in
                        guard !isDragging else { return }
                        withAnimation(.easeInOut(duration: 0.2)) {
                            centerOnAnchor(proxy: scrollProxy, width: geo.size.width)
                        }
                    }
                }
            }
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            )
        }
        .frame(minHeight: 200)
    }
    
    private func xForSample(_ s: Int, width: CGFloat) -> CGFloat {
        let ratio = CGFloat(s) / CGFloat(max(1, totalSamples - 1))
        return ratio * width
    }
    
    private func sampleForX(_ x: CGFloat, width: CGFloat) -> Int {
        let ratio = max(0, min(1, x / max(1, width)))
        return Int(ratio * CGFloat(totalSamples - 1))
    }
    
    private func centerOnAnchor(proxy: ScrollViewProxy? = nil, width: CGFloat = 0) {
        if let proxy = proxy {
            proxy.scrollTo("anchor", anchor: .center)
        }
    }
}

// Downsample full audio buffer to envelope for drawing
func downsampleToEnvelope(_ buffer: AVAudioPCMBuffer, points: Int) -> [Float] {
    let n = Int(buffer.frameLength)
    guard n > 0 else { return [] }
    let ch = Int(buffer.format.channelCount)
    let src0 = buffer.floatChannelData?[0]
    let src1 = ch > 1 ? buffer.floatChannelData?[1] : nil
    
    let step = max(1, n / max(1, points))
    var out: [Float] = []
    out.reserveCapacity(points)
    var i = 0
    while i < n && out.count < points {
        let end = min(n, i + step)
        var peak: Float = 0
        for k in i..<end {
            let v0 = src0?[k] ?? 0
            let v1 = src1?[k] ?? 0
            let m = (ch > 1) ? (0.5 * (abs(v0) + abs(v1))) : abs(v0)
            if m > peak { peak = m }
        }
        out.append(peak)
        i += step
    }
    // normalise to [-1..1] visual range
    if let maxv = out.max(), maxv > 0 {
        out = out.map { $0 / maxv }
    }
    return out
}