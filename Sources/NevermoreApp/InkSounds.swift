import AppKit

/// Four short cues for the ink, synthesized at launch so the bundle ships
/// no audio files. Each is under 200 ms and quiet; none carries
/// information the screen does not also show.
@MainActor enum InkSounds {
    enum Cue: CaseIterable { case lift, land, dry, takeBack, stick }

    static let preferenceKey = "inkSounds"
    /// On unless turned off in Settings ▸ General.
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: preferenceKey) as? Bool ?? true }

    private static let sampleRate = 44_100.0
    private static var sounds: [Cue: NSSound] = [:]

    static func play(_ cue: Cue) {
        guard isEnabled, !isSilenced else { return }
        let sound = sounds[cue] ?? {
            let sound = NSSound(data: wave(samples(for: cue)))
            sounds[cue] = sound
            return sound
        }()
        guard let sound else { return }
        if sound.isPlaying { sound.stop() }
        sound.volume = cue == .dry ? 0.35 : 0.5
        sound.play()
    }

    /// Automated runs open windows nobody is listening to.
    private static let isSilenced = ProcessInfo.processInfo.arguments.contains("--self-check") || ProcessInfo.processInfo.arguments.contains("--performance-check")

    /// Mono samples in -1...1.
    static func samples(for cue: Cue) -> [Double] {
        switch cue {
        case .lift: return breath(duration: 0.09, from: 900, to: 3200, gain: 0.16)
        case .takeBack: return breath(duration: 0.12, from: 3000, to: 700, gain: 0.16)
        case .land: return tap()
        case .stick: return thock()
        case .dry: return chime()
        }
    }

    /// Filtered noise whose brightness moves: paper leaving or meeting glass.
    private static func breath(duration: Double, from: Double, to: Double, gain: Double) -> [Double] {
        let count = Int(duration * sampleRate)
        var generator = SplitMix(seed: 0x1845)
        var low = 0.0
        return (0..<count).map { index in
            let progress = Double(index) / Double(count)
            let cutoff = from + (to - from) * progress
            // One-pole low-pass; the coefficient follows the moving cutoff.
            let coefficient = 1 - exp(-2 * .pi * cutoff / sampleRate)
            low += coefficient * (generator.unit() - low)
            let envelope = pow(sin(.pi * progress), 2)
            return low * envelope * gain * 3
        }
    }

    /// A soft knock: a sine falling from 210 Hz to 120 Hz in 70 ms, with
    /// 3 ms of noise at the front for the contact.
    private static func tap() -> [Double] {
        let count = Int(0.085 * sampleRate)
        var generator = SplitMix(seed: 0x2025)
        var phase = 0.0
        return (0..<count).map { index in
            let time = Double(index) / sampleRate
            let frequency = 120 + 90 * exp(-time / 0.018)
            phase += 2 * .pi * frequency / sampleRate
            let body = sin(phase) * exp(-time / 0.022)
            let contact = time < 0.003 ? generator.unit() * (1 - time / 0.003) * 0.25 : 0
            let attack = min(1, time / 0.0015)
            return (body * 0.55 + contact) * attack
        }
    }

    /// A sticker pressed onto paper: lower and rounder than the tap, a
    /// sine falling from 150 Hz to 85 Hz in 90 ms, with a short contact.
    private static func thock() -> [Double] {
        let count = Int(0.11 * sampleRate)
        var generator = SplitMix(seed: 0x51C4)
        var phase = 0.0
        return (0..<count).map { index in
            let time = Double(index) / sampleRate
            let frequency = 85 + 65 * exp(-time / 0.02)
            phase += 2 * .pi * frequency / sampleRate
            let body = sin(phase) * exp(-time / 0.03)
            let contact = time < 0.004 ? generator.unit() * (1 - time / 0.004) * 0.3 : 0
            let attack = min(1, time / 0.002)
            return (body * 0.6 + contact) * attack
        }
    }

    /// Two quiet partials a fifth apart, gone in 180 ms: delivered.
    private static func chime() -> [Double] {
        let count = Int(0.2 * sampleRate)
        return (0..<count).map { index in
            let time = Double(index) / sampleRate
            let attack = min(1, time / 0.004)
            let first = sin(2 * .pi * 1318.5 * time) * exp(-time / 0.05)
            let second = sin(2 * .pi * 1975.5 * time) * exp(-time / 0.035) * 0.5
            return (first + second) * attack * 0.22
        }
    }

    /// 16-bit mono PCM in a WAV container, which NSSound reads from memory.
    static func wave(_ samples: [Double]) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); append(36 + bytes); data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(sampleRate)); append(UInt32(sampleRate) * 2); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(bytes)
        for sample in samples { append(Int16((max(-1, min(1, sample)) * 32_767).rounded())) }
        return data
    }

    /// Deterministic noise, so every launch plays the same sound.
    private struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func unit() -> Double {
            state &+= 0x9E37_79B9_7F4A_7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
            value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
            value ^= value >> 31
            return Double(value >> 11) / Double(1 << 53) * 2 - 1
        }
    }
}
