import Foundation

/// Deterministic RNG (SplitMix64) used wherever a *reproducible* random
/// effect is needed — the same annotation with the same stored seed must
/// render identically every time (undo/redo, re-export, multiple preview
/// frames), rather than flickering with a fresh random result on every
/// draw call. Two call sites use this:
///   - `HandDrawnPath` — hand-drawn stroke wobble, reseeded on `Cmd+R`
///     ("randomizes hand-drawn appearance of a selected supported object").
///   - `Redaction/RedactionRenderer.swift` — secure randomized pixelation's
///     per-block shuffle.
///
/// NOT cryptographically secure. SplitMix64 is a fast, well-distributed,
/// *reproducible* generator, not a CSPRNG — see `RedactionRenderer`'s doc
/// comment for why "secure randomized pixelation" refers to resisting the
/// casual/naive reconstruction attacks that plain uniform pixelation is
/// vulnerable to, not to cryptographic security.
public struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    public init(seed: UInt64) {
        // SplitMix64 tolerates a zero state fine, but nudge away from 0 so
        // seed 0 doesn't produce a visibly different-looking first output
        // than neighbouring seeds.
        self.state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
