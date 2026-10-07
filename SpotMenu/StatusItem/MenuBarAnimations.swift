import AppKit
import SwiftUI

// MARK: - Equalizer bars

/// Bouncing bars in the menu bar. When real audio is available they follow
/// the music (driven by AudioSpectrumMonitor); otherwise they fall back to a
/// simulated bounce. They settle to a flat line when playback is paused.
struct EqualizerBarsView: View {
    let isPlaying: Bool
    let barCount: Int
    let barWidth: CGFloat
    let followMusic: Bool

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
                    .animation(.linear(duration: 1.0 / 30.0), value: monitor.levels)
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
                RoundedRectangle(cornerRadius: barWidth / 2)
                    .frame(width: barWidth, height: height(index))
            }
        }
    }

    /// Maps the monitor's bands onto however many bars are shown.
    private func realHeight(for index: Int) -> CGFloat {
        let levels = monitor.levels
        guard !levels.isEmpty else { return restHeight }
        let count = max(barCount, 1)
        let start = index * levels.count / count
        let end = max(start + 1, (index + 1) * levels.count / count)
        let slice = levels[start..<min(end, levels.count)]
        let value = slice.reduce(0, +) / Float(slice.count)
        return restHeight + CGFloat(value) * (Self.maxHeight - restHeight)
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
