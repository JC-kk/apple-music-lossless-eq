import Foundation

/// Parses AutoEQ / Squiglink `ParametricEQ.txt` files into a `PEQProfile`.
///
/// Expected shape:
///
///     Preamp: -6.85 dB
///     Filter 1: ON LSC Fc 105.0 Hz Gain 4.7 dB Q 0.70
///     Filter 2: ON PK  Fc 70.5  Hz Gain 0.3 dB Q 4.73
///     ...
///
/// Filter types: PK (peaking), LSC/LS (low shelf), HSC/HS (high shelf).
/// Lines with an unrecognised filter type are collected in
/// `Result.skippedLines` rather than failing the whole import.
enum AutoEQParser {
    struct Result {
        var preampDB: Double
        var bands: [PEQBand]
        var skippedLines: [String]
    }

    static func parse(_ text: String) -> Result {
        var preampDB = 0.0
        var bands: [PEQBand] = []
        var skipped: [String] = []

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            let lowercased = line.lowercased()
            if lowercased.hasPrefix("preamp") {
                if let value = firstSignedNumber(in: line) {
                    preampDB = value
                }
            } else if lowercased.hasPrefix("filter") {
                if let band = parseFilterLine(line) {
                    bands.append(band)
                } else {
                    skipped.append(line)
                }
            }
        }

        return Result(preampDB: preampDB, bands: bands, skippedLines: skipped)
    }

    /// Convenience: parse straight into an enabled profile.
    static func profile(from text: String, name: String) -> PEQProfile {
        let result = parse(text)
        return PEQProfile(name: name, preampDB: result.preampDB, bands: result.bands)
    }

    // MARK: - Line parsing

    // "Filter 1: ON PK Fc 105 Hz Gain 4.7 dB Q 0.70"
    private static func parseFilterLine(_ line: String) -> PEQBand? {
        let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let statusIndex = tokens.firstIndex(where: { $0 == "ON" || $0 == "OFF" }),
              statusIndex + 1 < tokens.count,
              let type = filterType(tokens[statusIndex + 1]),
              let frequency = value(after: "Fc", in: tokens) else {
            return nil
        }

        return PEQBand(isEnabled: tokens[statusIndex] == "ON",
                       type: type,
                       frequency: frequency,
                       gainDB: value(after: "Gain", in: tokens) ?? 0,
                       q: value(after: "Q", in: tokens) ?? 0.707)
    }

    private static func filterType(_ token: String) -> PEQFilterType? {
        switch token.uppercased() {
        case "PK", "PEQ": return .peak
        case "LS", "LSC", "LSQ": return .lowShelf
        case "HS", "HSC", "HSQ": return .highShelf
        default: return nil
        }
    }

    /// The numeric token immediately following `key` (e.g. the value after "Fc").
    private static func value(after key: String, in tokens: [String]) -> Double? {
        guard let index = tokens.firstIndex(of: key), index + 1 < tokens.count else {
            return nil
        }
        return Double(tokens[index + 1])
    }

    /// First signed decimal in a string — used for the "Preamp: -6.85 dB" line.
    private static func firstSignedNumber(in line: String) -> Double? {
        var buffer = ""
        for character in line {
            if character.isNumber || character == "." || character == "-" || character == "+" {
                buffer.append(character)
            } else if !buffer.isEmpty {
                if let value = Double(buffer) { return value }
                buffer = ""
            }
        }
        return Double(buffer)
    }
}
