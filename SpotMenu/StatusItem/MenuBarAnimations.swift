import AppKit
import SwiftUI

// MARK: - Equalizer bars

/// Small bouncing bars shown while music plays. They settle to a flat line
/// when playback is paused, and the timeline stops ticking so no CPU is used.
struct EqualizerBarsView: View {
    let isPlaying: Bool

    static let width: CGFloat = 12
    private let barCount = 4
    private let barWidth: CGFloat = 2
    private let barSpacing: CGFloat = 1.3
    private let maxHeight: CGFloat = 12
    private let restHeight: CGFloat = 2.5

    // Each bar gets its own speed and phase so they don't move in lockstep.
    private let speeds: [Double] = [5.3, 7.1, 6.2, 8.4]
    private let phases: [Double] = [0.0, 1.4, 2.7, 0.8]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !isPlaying)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: barSpacing) {
                ForEach(0..<barCount, id: \.self) { index in
                    RoundedRectangle(cornerRadius: barWidth / 2)
                        .frame(width: barWidth, height: height(for: index, at: t))
                }
            }
            .frame(width: Self.width, height: maxHeight, alignment: .bottom)
        }
        .animation(.easeOut(duration: 0.3), value: isPlaying)
    }

    private func height(for index: Int, at t: Double) -> CGFloat {
        guard isPlaying else { return restHeight }
        let speed = speeds[index % speeds.count]
        let phase = phases[index % phases.count]
        // Two layered sine waves give an organic, non-repeating bounce in 0...1.
        let value = (sin(t * speed + phase) + sin(t * speed * 0.53 + phase * 2)) / 4 + 0.5
        return restHeight + CGFloat(value) * (maxHeight - restHeight)
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
