import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Palette (matches GlassPanelView's 和風 language)

private enum EQWashi {
    static let rikyu = Color(red: 0.45, green: 0.47, blue: 0.26)    // 利休 — wabi-sabi green-gold
    static let ai = Color(red: 0.31, green: 0.39, blue: 0.45)       // 藍鼠 — muted indigo-grey
}

// MARK: - Equalizer window

struct EQView: View {
    @ObservedObject var eq: EQModel
    @State private var selectedBand: PEQBand.ID?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            Divider()
            EQGraph(profile: $eq.profile,
                    analyzer: eq.analyzer,
                    selectedBand: $selectedBand)
                .frame(minHeight: 220)
                .padding(12)
            hint
            Divider()
            bandTable
                .frame(minHeight: 130)
            statusBar
        }
        .frame(width: 470)
    }

    // MARK: Toolbar (two rows)

    private var toolbar: some View {
        VStack(spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("PARAMETRIC EQ")
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(2.5)
                    Text("パラメトリック・イコライザー")
                        .font(.system(size: 9))
                        .tracking(0.5)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Fixed-width slot so toggling the engine never reflows the row.
                Label(eq.currentSampleRate.map { sampleRateText($0) } ?? "—",
                      systemImage: "waveform.path")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .opacity(eq.currentSampleRate == nil ? 0 : 1)
                    .frame(width: 84, alignment: .trailing)

                Toggle("", isOn: Binding(get: { eq.isEnabled },
                                         set: { eq.setEnabled($0) }))
                    .toggleStyle(.switch)
                    .tint(EQWashi.rikyu)
                    .labelsHidden()
            }

            HStack(spacing: 10) {
                profileMenu
                TextField("Profile name", text: $eq.profile.name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 132)

                Spacer()

                Button { importAutoEQ() } label: { Label("Import", systemImage: "square.and.arrow.down") }
                    .help("Import AutoEQ…")
                Button { eq.addBand() } label: { Image(systemName: "plus") }
                    .help("Add")
                Button(role: .destructive) { eq.resetFlat() } label: { Image(systemName: "arrow.counterclockwise") }
                    .help("Flat")
            }

            HStack(spacing: 10) {
                Text("Preamp").font(.system(size: 11)).foregroundStyle(.secondary)
                Slider(value: $eq.profile.preampDB, in: -24...12)
                    .tint(EQWashi.rikyu)
                Text(String(format: "%+.1f dB", eq.profile.preampDB))
                    .font(.system(size: 11).monospacedDigit())
                    .frame(width: 56, alignment: .trailing)
            }
        }
    }

    private var profileMenu: some View {
        Menu {
            ForEach(eq.profiles) { item in
                Button {
                    eq.selectProfile(item.id)
                } label: {
                    if item.id == eq.profile.id {
                        Label(item.name, systemImage: "checkmark")
                    } else {
                        Text(item.name)
                    }
                }
            }
            Divider()
            Button { eq.newProfile() } label: { Label("New Profile", systemImage: "plus") }
            Button { eq.duplicateProfile() } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
            Button(role: .destructive) { eq.deleteProfile(eq.profile.id) } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(eq.profiles.count <= 1)
        } label: {
            Label(eq.profile.name, systemImage: "list.bullet")
        }
        .menuStyle(.borderlessButton)
        .frame(maxWidth: 124)
    }

    private var hint: some View {
        Text("Drag a point: frequency × gain · Scroll: Q")
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
            .padding(.bottom, 2)
    }

    // MARK: Band table

    private var bandTable: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach($eq.profile.bands) { $band in
                    BandRow(band: $band,
                            isSelected: selectedBand == band.id,
                            onSelect: { selectedBand = band.id },
                            onDelete: { eq.removeBand(band.id) })
                    Divider().opacity(0.4)
                }
                if eq.profile.bands.isEmpty {
                    Text("No bands. Add one, or import an AutoEQ ParametricEQ.txt.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 24)
                }
            }
            .padding(.horizontal, 12)
        }
    }

    private var statusBar: some View {
        HStack {
            Circle()
                .fill(eq.isEnabled ? EQWashi.rikyu : Color.secondary.opacity(0.5))
                .frame(width: 7, height: 7)
            Text(eq.statusMessage.isEmpty
                 ? (eq.isEnabled ? String(localized: "Equalizer active")
                                 : String(localized: "Bypassed — bit-perfect"))
                 : eq.statusMessage)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: Actions / helpers

    private func importAutoEQ() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.plainText, .text]
        panel.message = String(localized: "Choose an AutoEQ ParametricEQ.txt file")
        if panel.runModal() == .OK, let url = panel.url {
            eq.importAutoEQ(from: url)
        }
    }

    private func sampleRateText(_ rate: Double) -> String {
        let khz = rate / 1000
        return khz == khz.rounded()
            ? String(format: "%.0f kHz", khz)
            : String(format: "%.1f kHz", khz)
    }
}

// MARK: - One editable band row

private struct BandRow: View {
    @Binding var band: PEQBand
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: $band.isEnabled).labelsHidden()

            Picker("", selection: $band.type) {
                ForEach(PEQFilterType.allCases) { type in
                    Text(typeKey(type)).tag(type)
                }
            }
            .labelsHidden()
            .frame(width: 120)

            field("Freq", value: $band.frequency, unit: "Hz", width: 70)
            field("Gain", value: $band.gainDB, unit: "dB", width: 60)
            field("Q", value: $band.q, unit: "", width: 50)

            Spacer()

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash").font(.system(size: 11))
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(isSelected ? EQWashi.rikyu.opacity(0.12) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .opacity(band.isEnabled ? 1 : 0.45)
    }

    private func typeKey(_ type: PEQFilterType) -> LocalizedStringKey {
        switch type {
        case .peak: return "Peak"
        case .lowShelf: return "Low Shelf"
        case .highShelf: return "High Shelf"
        }
    }

    private func field(_ label: LocalizedStringKey, value: Binding<Double>,
                       unit: String, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 8)).foregroundStyle(.secondary)
            HStack(spacing: 2) {
                TextField("", value: value, format: .number.precision(.fractionLength(0...2)))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: width)
                    .font(.system(size: 11).monospacedDigit())
                if !unit.isEmpty {
                    Text(unit).font(.system(size: 8)).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Interactive response graph + spectrum

private struct EQGraph: View {
    @Binding var profile: PEQProfile
    @ObservedObject var analyzer: SpectrumAnalyzer
    @Binding var selectedBand: PEQBand.ID?
    @Environment(\.colorScheme) private var colorScheme

    private let dbRange: Double = 18
    private let fMin: Double = 20
    private let fMax: Double = 20_000
    private let displaySampleRate: Double = 48_000
    private let space = "eqgraph"

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    drawSpectrum(context, size)
                    drawGrid(context, size)
                    drawCurve(context, size)
                }
                .background(ScrollCatcher { deltaY in adjustSelectedQ(by: deltaY) })

                ForEach($profile.bands) { $band in
                    if band.isEnabled {
                        handle($band, size: geo.size)
                    }
                }
            }
            .coordinateSpace(name: space)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(colorScheme == .dark ? Color.black.opacity(0.25) : Color.white.opacity(0.4))
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    // MARK: Drawing

    private var gridColor: Color { (colorScheme == .dark ? Color.white : Color.black).opacity(0.10) }

    private func drawSpectrum(_ context: GraphicsContext, _ size: CGSize) {
        let levels = analyzer.levels
        guard levels.count > 1 else { return }
        var path = Path()
        path.move(to: CGPoint(x: 0, y: size.height))
        for i in levels.indices {
            let x = CGFloat(i) / CGFloat(levels.count - 1) * size.width
            let y = size.height - CGFloat(levels[i]) * size.height
            path.addLine(to: CGPoint(x: x, y: y))
        }
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.closeSubpath()
        context.fill(path, with: .color(EQWashi.ai.opacity(colorScheme == .dark ? 0.35 : 0.22)))
    }

    private func drawGrid(_ context: GraphicsContext, _ size: CGSize) {
        for f in [20.0, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000] {
            let x = xPos(f, width: size.width)
            var path = Path()
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(path, with: .color(gridColor), lineWidth: 0.5)
        }
        for g in stride(from: -12.0, through: 12.0, by: 6.0) {
            let y = yPos(g, height: size.height)
            var path = Path()
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(path, with: .color(g == 0 ? gridColor.opacity(2) : gridColor),
                           lineWidth: g == 0 ? 0.9 : 0.5)
        }
        for (f, label) in [(100.0, "100"), (1000.0, "1k"), (10000.0, "10k")] {
            context.draw(Text(label).font(.system(size: 8)).foregroundStyle(.secondary),
                         at: CGPoint(x: xPos(f, width: size.width), y: size.height - 8))
        }
    }

    private func drawCurve(_ context: GraphicsContext, _ size: CGSize) {
        let points = PEQResponse.curve(profile: profile, sampleRate: displaySampleRate,
                                       fMin: fMin, fMax: fMax, points: 220)
        guard points.count > 1 else { return }
        var line = Path()
        for (index, point) in points.enumerated() {
            let p = CGPoint(x: xPos(point.frequency, width: size.width),
                            y: yPos(point.db, height: size.height))
            if index == 0 { line.move(to: p) } else { line.addLine(to: p) }
        }
        context.stroke(line, with: .color(EQWashi.rikyu), lineWidth: 2)
    }

    // MARK: Handles

    private func handle(_ band: Binding<PEQBand>, size: CGSize) -> some View {
        let id = band.wrappedValue.id
        let isSelected = selectedBand == id
        let position = CGPoint(x: xPos(band.wrappedValue.frequency, width: size.width),
                               y: yPos(band.wrappedValue.gainDB, height: size.height))
        return Circle()
            .fill(EQWashi.rikyu.opacity(isSelected ? 1 : 0.7))
            .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: isSelected ? 2 : 1))
            .frame(width: isSelected ? 18 : 14, height: isSelected ? 18 : 14)
            .position(position)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
                    .onChanged { value in
                        selectedBand = id
                        band.wrappedValue.frequency = clampFreq(freqAt(value.location.x, width: size.width))
                        band.wrappedValue.gainDB = clampGain(dbAt(value.location.y, height: size.height))
                    }
            )
    }

    private func adjustSelectedQ(by deltaY: CGFloat) {
        guard let id = selectedBand,
              let index = profile.bands.firstIndex(where: { $0.id == id }) else { return }
        let factor = pow(1.04, Double(deltaY))
        let newQ = (profile.bands[index].q * factor)
        profile.bands[index].q = (min(max(newQ, 0.1), 12) * 100).rounded() / 100
    }

    // MARK: Coordinate mapping

    private func xPos(_ freq: Double, width: CGFloat) -> CGFloat {
        let t = (log10(max(freq, fMin)) - log10(fMin)) / (log10(fMax) - log10(fMin))
        return CGFloat(t) * width
    }

    private func freqAt(_ x: CGFloat, width: CGFloat) -> Double {
        let t = Double(max(0, min(1, width == 0 ? 0 : x / width)))
        return pow(10, log10(fMin) + t * (log10(fMax) - log10(fMin)))
    }

    private func yPos(_ db: Double, height: CGFloat) -> CGFloat {
        let clamped = max(-dbRange, min(dbRange, db))
        return height / 2 - CGFloat(clamped / dbRange) * (height / 2)
    }

    private func dbAt(_ y: CGFloat, height: CGFloat) -> Double {
        guard height > 0 else { return 0 }
        return Double((height / 2 - y) / (height / 2)) * dbRange
    }

    private func clampFreq(_ f: Double) -> Double { min(max(f, fMin), fMax) }
    private func clampGain(_ g: Double) -> Double { (min(max(g, -dbRange), dbRange) * 10).rounded() / 10 }
}

// MARK: - Scroll-wheel capture (for Q on the graph)

private struct ScrollCatcher: NSViewRepresentable {
    let onScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = CatcherView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? CatcherView)?.onScroll = onScroll
    }

    final class CatcherView: NSView {
        var onScroll: ((CGFloat) -> Void)?
        override func scrollWheel(with event: NSEvent) {
            onScroll?(event.scrollingDeltaY)
        }
    }
}
