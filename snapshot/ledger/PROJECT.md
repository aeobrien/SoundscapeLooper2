# SoundscapeLooper

> Ambient soundscape creator — drop audio files, select sections, loop them at different lengths overlapping each other to create rhythmic soundscapes.

## Overview

SoundscapeLooper lets you import audio files, select specific sections within them, and loop those sections simultaneously at different loop lengths. The overlapping loops create evolving, rhythmic ambient soundscapes from source material. Clean rewrite (migrated from SoundscapeLooper2).

**Platform:** iOS / macOS (Xcode project)
**Language:** Swift (SwiftUI)
**Audio:** Custom audio engine (AVFoundation-based)

## Architecture

### Code Organisation

```
SoundscapeLooper2/
  SoundscapeLooper2App.swift  — App entry point
  ContentView.swift           — Main UI
  Models.swift                — Data models (loops, sections, soundscapes)
  AudioEngine.swift           — Audio playback engine, loop management
  WaveformView.swift          — Waveform display for section selection
```

### Key Concepts

- **Section selection:** User selects a region within an audio file
- **Multi-loop overlay:** Multiple sections loop simultaneously at independent lengths
- **Polyrhythmic texture:** Different loop lengths create evolving phase relationships

## Subsystems

| Subsystem | Status | Document |
|-----------|--------|----------|
| Audio Engine | Early | — |
| Waveform UI | Early | — |

## Phase

**Early development / stalled.** Basic structure exists but incomplete.

## Linked Projects

| Project | Relationship | Notes |
|---------|-------------|-------|
| — | — | — |

## Open Questions

- Current state of audio engine implementation
- Whether section selection UI is functional
- Target platform (iOS, macOS, or both)

**Lane:** personal
