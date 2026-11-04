
import Foundation

// MARK: - Musical Subdivision

enum SubdivisionKind: String, CaseIterable, Identifiable {
    case thirtySecond = "1/32"
    case sixteenth     = "1/16"
    case eighth        = "1/8"
    case quarter       = "1/4"
    case half          = "1/2"
    case whole         = "1/1"
    var id: String { rawValue }
    
    // Duration in beats (quarter note = 1 beat)
    var beats: Double {
        switch self {
        case .whole:         return 4.0
        case .half:          return 2.0
        case .quarter:       return 1.0
        case .eighth:        return 0.5
        case .sixteenth:     return 0.25
        case .thirtySecond:  return 0.125
        }
    }
}

enum SubdivisionModifier: String, CaseIterable, Identifiable {
    case normal = "Normal"
    case dotted = "Dotted"
    case triplet = "Triplet"
    var id: String { rawValue }
    
    var factor: Double {
        switch self {
        case .normal:  return 1.0
        case .dotted:  return 1.5
        case .triplet: return 2.0/3.0
        }
    }
}

struct Subdivision: Identifiable, Equatable {
    var id = UUID()
    var kind: SubdivisionKind = .eighth
    var modifier: SubdivisionModifier = .normal
    var count: Int = 1
    
    // Duration in seconds for given BPM
    func seconds(bpm: Double) -> Double {
        let secPerBeat = 60.0 / max(1.0, bpm)
        return kind.beats * modifier.factor * Double(max(1, count)) * secPerBeat
    }
}

// MARK: - Playback Direction

enum PlaybackMode: String, CaseIterable, Identifiable {
    case forward = "Forward"
    case reverse = "Reverse"
    case pingPong = "Ping-Pong"
    case reverseThenForward = "Reverse→Forward"
    case random = "Random"
    var id: String { rawValue }
}

// MARK: - Voice Configuration

struct VoiceConfig: Identifiable, Equatable {
    let id: UUID
    var name: String
    var subdivision: Subdivision
    var playback: PlaybackMode = .forward
    var volume: Float = 0.9
    var pan: Float = 0.0     // -1...1
    var mute: Bool = false
    var solo: Bool = false
    
    init(index: Int) {
        self.id = UUID()
        self.name = "Voice \(index)"
        self.subdivision = Subdivision(kind: index % 2 == 0 ? .eighth : .quarter, modifier: .normal)
    }
}
