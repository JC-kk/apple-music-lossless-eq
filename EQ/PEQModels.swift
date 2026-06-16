import Foundation

// MARK: - Filter vocabulary

/// The parametric filter shapes Choritsu supports. The raw values mirror
/// AutoEQ's `ParametricEQ.txt` tokens so profiles round-trip cleanly.
enum PEQFilterType: String, Codable, CaseIterable, Identifiable {
    case peak       // AutoEQ: PK
    case lowShelf   // AutoEQ: LSC / LS
    case highShelf  // AutoEQ: HSC / HS

    var id: String { rawValue }

    /// The token written into an AutoEQ-style export.
    var autoEQToken: String {
        switch self {
        case .peak: return "PK"
        case .lowShelf: return "LSC"
        case .highShelf: return "HSC"
        }
    }

    var displayName: String {
        switch self {
        case .peak: return "Peak"
        case .lowShelf: return "Low Shelf"
        case .highShelf: return "High Shelf"
        }
    }
}

// MARK: - Band

/// A single parametric EQ band: one biquad's worth of parameters.
struct PEQBand: Identifiable, Codable, Equatable {
    var id: UUID
    var isEnabled: Bool
    var type: PEQFilterType
    /// Centre / corner frequency in Hz.
    var frequency: Double
    var gainDB: Double
    /// Quality factor. AutoEQ shelves default to ~0.707.
    var q: Double

    init(id: UUID = UUID(),
         isEnabled: Bool = true,
         type: PEQFilterType = .peak,
         frequency: Double = 1000,
         gainDB: Double = 0,
         q: Double = 0.707) {
        self.id = id
        self.isEnabled = isEnabled
        self.type = type
        self.frequency = frequency
        self.gainDB = gainDB
        self.q = q
    }
}

// MARK: - Profile

/// A named set of bands plus a preamp — typically one per headphone.
/// AutoEQ presets are mono curves applied identically to both channels.
struct PEQProfile: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    /// Global gain applied before the bands, in dB. AutoEQ ships this negative
    /// to leave headroom for the boosts and avoid clipping.
    var preampDB: Double
    var bands: [PEQBand]

    init(id: UUID = UUID(),
         name: String,
         preampDB: Double = 0,
         bands: [PEQBand] = []) {
        self.id = id
        self.name = name
        self.preampDB = preampDB
        self.bands = bands
    }

    static let flat = PEQProfile(name: "Flat")
}
