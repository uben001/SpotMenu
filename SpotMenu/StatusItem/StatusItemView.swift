import SwiftUI

struct StatusItemView: View {
    @ObservedObject var model: StatusItemModel
    @ObservedObject var menuBarPreferencesModel: MenuBarPreferencesModel
    @ObservedObject var musicPlayerPreferencesModel: MusicPlayerPreferencesModel
    @ObservedObject var playbackModel: PlaybackModel

    @State private var pulse = false

    private let spacing: CGFloat = 4
    private let appIconWidth: CGFloat = 16
    private let heartIconWidth: CGFloat = 13
    private let noteIconWidth: CGFloat = 11

    var body: some View {
        content
            .frame(maxWidth: menuBarPreferencesModel.maxStatusItemWidth)
            .padding(.horizontal, 0)
            .padding(.vertical, 2)
            .background(Color.clear)
            .lineLimit(1)
            .truncationMode(.tail)
            .onChange(of: model.isPlaying) { _ in triggerPulse() }
    }

    // MARK: - Layout

    private var content: some View {
        let options = model.computeDisplayOptions(
            menuBarPreferencesModel: menuBarPreferencesModel,
            musicPlayerPreferencesModel: musicPlayerPreferencesModel,
            playbackModel: playbackModel
        )
        let prefs = menuBarPreferencesModel
        let hasTrack = !model.artist.isEmpty || !model.title.isEmpty

        // Equalizer replaces the static ♫ icon. It stays visible (flat) while
        // paused so the bars can visibly "settle" and bounce back on play.
        let showEqualizer =
            prefs.animateEqualizer && prefs.showIsPlayingIcon
            && (model.isPlaying || hasTrack)
        let showNote = !prefs.animateEqualizer && options.showMusicIcon

        let textWidth = availableTextWidth(
            options: options,
            showEqualizer: showEqualizer,
            showNote: showNote
        )

        return HStack(spacing: spacing) {
            if options.showIcon {
                Image(model.playerIconName)
                    .renderingMode(.template)
                    .resizable()
                    .frame(width: appIconWidth, height: appIconWidth)
                    .clipShape(Circle())
                    .pulsing(pulse)
            }

            if options.showHeartIcon {
                Image(systemName: "heart.fill")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: heartIconWidth, height: heartIconWidth)
                    .transition(.opacity)
            }

            if showEqualizer {
                EqualizerBarsView(
                    isPlaying: model.isPlaying,
                    barCount: prefs.equalizerBarCount,
                    barWidth: CGFloat(prefs.equalizerBarWidth),
                    followMusic: prefs.equalizerFollowsMusic,
                    bassBarCount: prefs.equalizerBassBars,
                    shuffleKey: trackKey
                )
                .pulsing(pulse)
            } else if showNote {
                Text("♫").font(.system(size: 13))
                    .pulsing(pulse)
            }

            if options.showText {
                ZStack {
                    textContent(options: options, maxWidth: textWidth)
                        .id(trackKey)
                        .transition(trackChangeTransition)
                }
                .animation(
                    prefs.animateTrackChange ? .easeInOut(duration: 0.35) : nil,
                    value: trackKey
                )
                .clipped()
            }
        }
    }

    @ViewBuilder
    private func textContent(options: StatusItemModel.DisplayOptions, maxWidth: CGFloat)
        -> some View
    {
        let prefs = menuBarPreferencesModel

        if options.showCompact {
            VStack(spacing: -2) {
                if options.showArtist {
                    line(model.artist, size: 10, weight: prefs.fontWeightCompactTop, maxWidth: maxWidth)
                }
                if options.showTitle {
                    line(model.title, size: 9, weight: prefs.fontWeightCompactBottom, maxWidth: maxWidth)
                }
            }
        } else if prefs.scrollLongText {
            MarqueeText(
                text: model.buildFullText(displayOptions: options),
                fontSize: 13,
                weight: prefs.fontWeightNormal,
                maxWidth: maxWidth,
                isActive: model.isPlaying
            )
        } else {
            Text(
                model.buildText(
                    displayOptions: options,
                    font: NSFont.systemFont(ofSize: 13)
                )
            )
            .font(.system(size: 13, weight: prefs.fontWeightNormal.fontWeight))
        }
    }

    @ViewBuilder
    private func line(_ text: String, size: CGFloat, weight: MenuBarFontWeight, maxWidth: CGFloat)
        -> some View
    {
        if menuBarPreferencesModel.scrollLongText {
            MarqueeText(
                text: text,
                fontSize: size,
                weight: weight,
                maxWidth: maxWidth,
                isActive: model.isPlaying
            )
        } else {
            Text(text).font(.system(size: size, weight: weight.fontWeight))
        }
    }

    // MARK: - Helpers

    private var trackKey: String {
        model.artist + "\u{1F}" + model.title
    }

    private var trackChangeTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity),
            removal: .move(edge: .top).combined(with: .opacity)
        )
    }

    /// Width left for text once the visible icons are accounted for.
    private func availableTextWidth(
        options: StatusItemModel.DisplayOptions,
        showEqualizer: Bool,
        showNote: Bool
    ) -> CGFloat {
        var used: CGFloat = 0
        if options.showIcon { used += appIconWidth + spacing }
        if options.showHeartIcon { used += heartIconWidth + spacing }
        if showEqualizer {
            used += EqualizerBarsView.width(
                barCount: menuBarPreferencesModel.equalizerBarCount,
                barWidth: CGFloat(menuBarPreferencesModel.equalizerBarWidth)
            ) + spacing
        }
        else if showNote { used += noteIconWidth + spacing }
        return max(menuBarPreferencesModel.maxStatusItemWidth - used, 20)
    }

    private func triggerPulse() {
        guard menuBarPreferencesModel.pulseOnPlayPause else { return }
        withAnimation(.spring(response: 0.16, dampingFraction: 0.5)) {
            pulse = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.65)) {
                pulse = false
            }
        }
    }
}

#Preview {
    let model = StatusItemModel()
    model.artist = "test"
    model.title =
        "very long text that should be truncated very very long text"
    model.isPlaying = true

    let preferences = MenuBarPreferencesModel()
    preferences.showArtist = true
    preferences.showTitle = true
    preferences.showIsPlayingIcon = true
    preferences.compactView = false

    let playbackModel = PlaybackModel(
        preferences: MusicPlayerPreferencesModel()
    )
    return StatusItemView(
        model: model,
        menuBarPreferencesModel: preferences,
        musicPlayerPreferencesModel: MusicPlayerPreferencesModel(),
        playbackModel: playbackModel
    )
}
