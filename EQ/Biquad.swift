import Foundation

/// Normalised biquad coefficients (a0 folded to 1), derived from a `PEQBand`
/// using the Robert Bristow-Johnson Audio EQ Cookbook formulas — the same math
/// Equalizer APO, PipeWire and most players use, so imported AutoEQ presets
/// sound the way their authors intended.
///
/// These are used two ways: to draw the response curve in the UI (via
/// `magnitude`), and as the reference the audio engine configures
/// `AVAudioUnitEQ` to match. Coefficients are sample-rate dependent, so they
/// must be recomputed whenever the output device's rate changes.
struct BiquadCoefficients: Equatable {
    var b0: Double
    var b1: Double
    var b2: Double
    var a1: Double
    var a2: Double

    /// A pass-through (unity) biquad.
    static let identity = BiquadCoefficients(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

    init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0
        self.b1 = b1
        self.b2 = b2
        self.a1 = a1
        self.a2 = a2
    }

    init(band: PEQBand, sampleRate: Double) {
        guard sampleRate > 0, band.frequency > 0, band.q > 0,
              band.frequency < sampleRate / 2 else {
            self = .identity
            return
        }

        let a = pow(10.0, band.gainDB / 40.0)            // amplitude, sqrt of linear gain
        let w0 = 2.0 * Double.pi * band.frequency / sampleRate
        let cosW0 = cos(w0)
        let sinW0 = sin(w0)
        let alpha = sinW0 / (2.0 * band.q)

        var b0 = 1.0, b1 = 0.0, b2 = 0.0
        var a0 = 1.0, a1 = 0.0, a2 = 0.0

        switch band.type {
        case .peak:
            b0 = 1 + alpha * a
            b1 = -2 * cosW0
            b2 = 1 - alpha * a
            a0 = 1 + alpha / a
            a1 = -2 * cosW0
            a2 = 1 - alpha / a

        case .lowShelf:
            let sq = 2 * sqrt(a) * alpha
            b0 =      a * ((a + 1) - (a - 1) * cosW0 + sq)
            b1 =  2 * a * ((a - 1) - (a + 1) * cosW0)
            b2 =      a * ((a + 1) - (a - 1) * cosW0 - sq)
            a0 =          (a + 1) + (a - 1) * cosW0 + sq
            a1 =     -2 * ((a - 1) + (a + 1) * cosW0)
            a2 =          (a + 1) + (a - 1) * cosW0 - sq

        case .highShelf:
            let sq = 2 * sqrt(a) * alpha
            b0 =      a * ((a + 1) + (a - 1) * cosW0 + sq)
            b1 = -2 * a * ((a - 1) + (a + 1) * cosW0)
            b2 =      a * ((a + 1) + (a - 1) * cosW0 - sq)
            a0 =          (a + 1) - (a - 1) * cosW0 + sq
            a1 =      2 * ((a - 1) - (a + 1) * cosW0)
            a2 =          (a + 1) - (a - 1) * cosW0 - sq
        }

        self.b0 = b0 / a0
        self.b1 = b1 / a0
        self.b2 = b2 / a0
        self.a1 = a1 / a0
        self.a2 = a2 / a0
    }

    /// Linear magnitude of the transfer function evaluated on the unit circle
    /// at `frequency`. Used to plot the response curve.
    func magnitude(atFrequency frequency: Double, sampleRate: Double) -> Double {
        let w = 2.0 * Double.pi * frequency / sampleRate
        let cosW = cos(w), sinW = sin(w)
        let cos2W = cos(2 * w), sin2W = sin(2 * w)

        let numRe = b0 + b1 * cosW + b2 * cos2W
        let numIm = -(b1 * sinW + b2 * sin2W)
        let denRe = 1 + a1 * cosW + a2 * cos2W
        let denIm = -(a1 * sinW + a2 * sin2W)

        let numMag = (numRe * numRe + numIm * numIm).squareRoot()
        let denMag = (denRe * denRe + denIm * denIm).squareRoot()
        return denMag == 0 ? 0 : numMag / denMag
    }
}

/// Computes the combined frequency response of a whole profile, for the UI graph.
enum PEQResponse {
    struct Point: Equatable {
        let frequency: Double
        let db: Double
    }

    /// Combined magnitude in dB at one frequency, including the preamp and all
    /// enabled bands.
    static func magnitudeDB(profile: PEQProfile,
                            frequency: Double,
                            sampleRate: Double) -> Double {
        var db = profile.preampDB
        for band in profile.bands where band.isEnabled {
            let coefficients = BiquadCoefficients(band: band, sampleRate: sampleRate)
            let magnitude = coefficients.magnitude(atFrequency: frequency, sampleRate: sampleRate)
            if magnitude > 0 {
                db += 20.0 * log10(magnitude)
            }
        }
        return db
    }

    /// A log-spaced response curve over `[fMin, fMax]` for plotting.
    ///
    /// On top of the evenly log-spaced grid, each enabled band's centre
    /// frequency and -3 dB skirts are injected into the sample set. A high-Q
    /// peak is narrow enough to fall *between* grid points, which renders its
    /// apex too short and quantises the tip's width to the grid spacing — so the
    /// peak would stop looking sharper as Q climbs past ~1. Sampling each peak at
    /// its centre guarantees the apex and width are drawn faithfully at any Q.
    static func curve(profile: PEQProfile,
                      sampleRate: Double,
                      fMin: Double = 20,
                      fMax: Double = 20_000,
                      points: Int = 480) -> [Point] {
        guard points > 1, fMin > 0, fMax > fMin else { return [] }
        let logMin = log10(fMin)
        let logMax = log10(fMax)
        let nyquist = sampleRate / 2

        var frequencies = (0..<points).map { index in
            pow(10.0, logMin + Double(index) / Double(points - 1) * (logMax - logMin))
        }

        for band in profile.bands where band.isEnabled {
            let fc = band.frequency
            guard fc > fMin, fc < fMax else { continue }
            let halfBandwidth = fc / max(band.q, 0.1) / 2     // ≈ half the -3 dB width
            for offset in [-2.0, -1, -0.5, -0.25, 0, 0.25, 0.5, 1, 2] {
                let f = fc + offset * halfBandwidth
                if f > fMin, f < fMax { frequencies.append(f) }
            }
        }

        frequencies.sort()

        return frequencies.map { frequency in
            let f = min(frequency, nyquist - 1)
            return Point(frequency: f,
                         db: magnitudeDB(profile: profile,
                                         frequency: f,
                                         sampleRate: sampleRate))
        }
    }
}
