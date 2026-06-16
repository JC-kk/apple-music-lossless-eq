import Foundation

/// Real-time biquad cascade used inside the Core Audio IOProc.
///
/// One independent delay line per channel; the same coefficients are applied to
/// every channel because AutoEQ curves are mono. Filtering uses Transposed
/// Direct Form II, which is numerically well behaved in 32/64-bit float.
///
/// `process` runs on the audio render thread and never allocates or locks.
/// Coefficients are rebuilt off the audio thread by `setSections(_:preampDB:)`
/// and handed over with a double-buffered swap: the writer fills the inactive
/// slot, then flips `activeSlot` (a single Int — its read/write is atomic on the
/// platforms we target). Worst case during a flip is one render cycle of
/// slightly stale coefficients, which is inaudible.
///
/// Prototype caveat: binding `slots[slot]` to a local on the audio thread does
/// one atomic ARC retain (no allocation). Fine for the prototype; if profiling
/// ever flags it, swap the slots for preallocated `UnsafeMutableBufferPointer`s.
final class BiquadProcessor {
    private static let maxSections = 32
    private static let maxChannels = 8

    private var z1: [Double]
    private var z2: [Double]

    private var slots: [[BiquadCoefficients]] = [[], []]
    private var preampLinear: [Double] = [1, 1]
    private var activeSlot = 0

    /// When true, `process` returns immediately (true passthrough).
    var bypass = true

    init() {
        z1 = [Double](repeating: 0, count: Self.maxChannels * Self.maxSections)
        z2 = [Double](repeating: 0, count: Self.maxChannels * Self.maxSections)
    }

    /// Rebuild the cascade off the audio thread. `preampDB` is folded into a
    /// linear input gain so AutoEQ's headroom preamp is honoured.
    func setSections(_ coefficients: [BiquadCoefficients], preampDB: Double) {
        let clamped = Array(coefficients.prefix(Self.maxSections))
        let inactive = 1 - activeSlot
        slots[inactive] = clamped
        preampLinear[inactive] = pow(10.0, preampDB / 20.0)
        activeSlot = inactive
    }

    /// Clear delay lines, e.g. after a sample-rate change, to avoid a transient.
    func reset() {
        for index in z1.indices { z1[index] = 0; z2[index] = 0 }
    }

    /// Filter one non-interleaved float channel buffer in place.
    func process(_ samples: UnsafeMutablePointer<Float>, frameCount: Int, channel: Int) {
        guard !bypass, channel < Self.maxChannels else { return }

        let slot = activeSlot
        let sections = slots[slot]
        let gain = preampLinear[slot]
        let count = min(sections.count, Self.maxSections)
        guard count > 0 || gain != 1 else { return }

        let base = channel * Self.maxSections
        for frame in 0..<frameCount {
            var x = Double(samples[frame]) * gain
            for s in 0..<count {
                let c = sections[s]
                let index = base + s
                let y = c.b0 * x + z1[index]
                z1[index] = c.b1 * x - c.a1 * y + z2[index]
                z2[index] = c.b2 * x - c.a2 * y
                x = y
            }
            samples[frame] = Float(x)
        }
    }
}
