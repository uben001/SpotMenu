import AppKit
import SwiftUI

// MARK: - Equalizer bars

/// Bouncing bars in the menu bar. When real audio is available they follow
/// the music (driven by AudioSpectrumMonitor): a few randomly placed bars
/// follow only the bass, the rest follow the rest of the music. Otherwise they fall back to a
/// simulated bounce. They settle to a flat line when playback is paused.
struct EqualizerBarsView: View {
    let isPlaying: Bool
    let barCount: Int
    let barWidth: CGFloat
    let followMusic: Bool
    /// How many bars follow only the bass (at random positions).
    var bassBarCount: Int = 2
    /// Changing this (e.g. on every new song) reshuffles which bars are bass bars.
    var shuffleKey: String = ""

    @ObservedObject private var monitor = AudioSpectrumMonitor.shared

    static let maxHeight: CGFloat = 14
    private let restHeight: CGFloat = 2

    static func spacing(for barWidth: CGFloat) -> CGFloat {
        max(1, (barWidth * 0.6).rounded(.toNearestOrAwayFromZero))
    }

    static func width(barCount: Int, barWidth: CGFloat) -> CGFloat {
        let n = CGFloat(max(barCount, 1))
        return n * barWidth + (n - 1) * spacing(for: barWidth)
    }

    // Simulated mode: each bar gets its own speed and phase.
    private let speeds: [Double] = [5.3, 7.1, 6.2, 8.4, 5.9, 7.7, 6.6, 8.9, 5.6, 7.3]
    private let phases: [Double] = [0.0, 1.4, 2.7, 0.8, 2.1, 0.3, 1.9, 2.4, 1.1, 0.6]

    private var usingRealAudio: Bool {
        followMusic && isPlaying && monitor.isReceiving
    }

    var body: some View {
        Group {
            if usingRealAudio {
                bars { index in realHeight(for: index) }
                    .animation(.linear(duration: 1.0 / 30.0), value: monitor.restLevels)
                    .animation(.linear(duration: 1.0 / 30.0), value: monitor.bassLevels)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !isPlaying)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    bars { index in simulatedHeight(for: index, at: t) }
                }
            }
        }
        .frame(
            width: Self.width(barCount: barCount, barWidth: barWidth),
            height: Self.maxHeight,
            alignment: .bottom
        )
        .animation(.easeOut(duration: 0.3), value: isPlaying)
    }

    private func bars(_ height: @escaping (Int) -> CGFloat) -> some View {
        HStack(alignment: .bottom, spacing: Self.spacing(for: barWidth)) {
            ForEach(0..<max(barCount, 1), id: \.self) { index in
                Rectangle()
                    .frame(width: barWidth, height: height(index))
            }
        }
    }

    /// Which bar positions are bass bars, chosen at random but stable for a
    /// given song / bar layout (so bars don't swap roles while you listen).
    private var bassPositions: [Int] {
        let count = max(barCount, 1)
        let bassBars = min(max(bassBarCount, 0), count)
        var generator = SeededGenerator(seed: "\(shuffleKey)|\(count)|\(bassBars)")
        let shuffled = Array(0..<count).shuffled(using: &generator)
        return Array(shuffled.prefix(bassBars)).sorted()
    }

    /// Bass bars take the bass bands; the remaining bars take the rest of
    /// the spectrum, low to high from left to right.
    private func realHeight(for index: Int) -> CGFloat {
        let count = max(barCount, 1)
        let bass = bassPositions
        let value: Float
        if let slot = bass.firstIndex(of: index) {
            value = sample(monitor.bassLevels, bar: slot, of: bass.count)
        } else {
            let others = (0..<count).filter { !bass.contains($0) }
            let slot = others.firstIndex(of: index) ?? 0
            value = sample(monitor.restLevels, bar: slot, of: others.count)
        }
        return restHeight + CGFloat(value) * (Self.maxHeight - restHeight)
    }

    private func sample(_ levels: [Float], bar: Int, of bars: Int) -> Float {
        guard !levels.isEmpty, bars > 0 else { return 0 }
        let start = bar * levels.count / bars
        let end = max(start + 1, (bar + 1) * levels.count / bars)
        let slice = levels[min(start, levels.count - 1)..<min(end, levels.count)]
        return slice.reduce(0, +) / Float(max(slice.count, 1))
    }

    private func simulatedHeight(for index: Int, at t: Double) -> CGFloat {
        guard isPlaying else { return restHeight }
        let speed = speeds[index % speeds.count]
        let phase = phases[index % phases.count]
        // Two layered sine waves give an organic, non-repeating bounce in 0...1.
        let value = (sin(t * speed + phase) + sin(t * speed * 0.53 + phase * 2)) / 4 + 0.5
        return restHeight + CGFloat(value) * (Self.maxHeight - restHeight)
    }
}

// MARK: - Scrolling (marquee) text

/// Shows text as-is when it fits. When it doesn't fit and music is playing,
/// it scrolls like a ticker: holds at the start, slides through, loops.
/// When paused it falls back to normal truncated text (and stops animating).
struct MarqueeText: View {
    let text: String
    let fontSize: CGFloat
    let weight: MenuBarFontWeight
    let maxWidth: CGFloat
    let isActive: Bool

    var speed: CGFloat = 28          // points per second
    var gap: CGFloat = 28            // space between the end and the repeated start
    var pauseAtStart: TimeInterval = 2.0

    @State private var startDate = Date()

    private var font: Font { .system(size: fontSize, weight: weight.fontWeight) }

    private var measuredWidth: CGFloat {
        let nsFont = NSFont.systemFont(ofSize: fontSize, weight: weight.nsFontWeight)
        return ceil((text as NSString).size(withAttributes: [.font: nsFont]).width)
    }

    var body: some View {
        let textWidth = measuredWidth
        let available = max(maxWidth, 0)

        Group {
            if textWidth <= available {
                Text(text)
                    .font(font)
                    .fixedSize()
            } else if !isActive {
                Text(text)
                    .font(font)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: available, alignment: .leading)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    let offset = scrollOffset(at: context.date, textWidth: textWidth)
                    HStack(spacing: gap) {
                        Text(text)
                        Text(text)
                    }
                    .font(font)
                    .fixedSize()
                    .offset(x: -offset)
                    .frame(width: available, alignment: .leading)
                    .clipped()
                    .mask(edgeFade(leadingFaded: offset > 0))
                }
            }
        }
        .onChange(of: text) { _ in startDate = Date() }
        .onChange(of: isActive) { active in
            if active { startDate = Date() }
        }
    }

    private func scrollOffset(at date: Date, textWidth: CGFloat) -> CGFloat {
        let travel = textWidth + gap
        let cycle = pauseAtStart + Double(travel / speed)
        let t = date.timeIntervalSince(startDate).truncatingRemainder(dividingBy: cycle)
        guard t > pauseAtStart else { return 0 }
        return CGFloat(t - pauseAtStart) * speed
    }

    private func edgeFade(leadingFaded: Bool) -> some View {
        LinearGradient(
            stops: [
                .init(color: leadingFaded ? .clear : .black, location: 0),
                .init(color: .black, location: 0.06),
                .init(color: .black, location: 0.92),
                .init(color: .clear, location: 1),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

// MARK: - Pulse

extension View {
    /// Briefly scales the view up when `active` flips true.
    func pulsing(_ active: Bool) -> some View {
        scaleEffect(active ? 1.25 : 1.0)
    }
}

// MARK: - Seeded random

/// Small deterministic random generator (SplitMix64) so the same song always
/// gets the same bass-bar layout.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: String) {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325  // FNV-1a
        for byte in seed.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        state = hash
    }

    mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }
}
