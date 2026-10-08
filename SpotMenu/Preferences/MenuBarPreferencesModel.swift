import AppKit
import Combine
import Foundation
import SwiftUI

enum MenuBarFontWeight: String, CaseIterable {
    case ultraLight = "ultraLight"
    case thin = "thin"
    case light = "light"
    case regular = "regular"
    case medium = "medium"
    case semibold = "semibold"
    case bold = "bold"
    case heavy = "heavy"
    case black = "black"

    var fontWeight: Font.Weight {
        switch self {
        case .ultraLight: return .ultraLight
        case .thin: return .thin
        case .light: return .light
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        }
    }

    var nsFontWeight: NSFont.Weight {
        switch self {
        case .ultraLight: return .ultraLight
        case .thin: return .thin
        case .light: return .light
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        }
    }
}

class MenuBarPreferencesModel: ObservableObject {
    @Published var showArtist: Bool {
        didSet {
            UserDefaults.standard.set(showArtist, forKey: "menuBar.showArtist")
        }
    }
    @Published var showTitle: Bool {
        didSet {
            UserDefaults.standard.set(showTitle, forKey: "menuBar.showTitle")
        }
    }
    @Published var showIsPlayingIcon: Bool {
        didSet {
            UserDefaults.standard.set(
                showIsPlayingIcon,
                forKey: "menuBar.showIsPlayingIcon"
            )
        }
    }
    @Published var showIsLikedIcon: Bool {
        didSet {
            UserDefaults.standard.set(
                showIsLikedIcon,
                forKey: "menuBar.showIsLikedIcon"
            )
        }
    }
    @Published var showAppIcon: Bool {
        didSet {
            UserDefaults.standard.set(
                showAppIcon,
                forKey: "menuBar.showAppIcon"
            )
        }
    }
    @Published var compactView: Bool {
        didSet {
            UserDefaults.standard.set(
                compactView,
                forKey: "menuBar.compactView"
            )
        }
    }
    @Published var maxStatusItemWidth: CGFloat {
        didSet {
            UserDefaults.standard.set(
                maxStatusItemWidth,
                forKey: "menuBar.maxStatusItemWidth"
            )
        }
    }
    @Published var hideArtistWhenPaused: Bool {
        didSet {
            UserDefaults.standard.set(
                hideArtistWhenPaused,
                forKey: "menuBar.hideArtistWhenPaused"
            )
        }
    }
    @Published var hideTitleWhenPaused: Bool {
        didSet {
            UserDefaults.standard.set(
                hideTitleWhenPaused,
                forKey: "menuBar.hideTitleWhenPaused"
            )
        }
    }
    @Published var fontWeightCompactTop: MenuBarFontWeight {
        didSet {
            UserDefaults.standard.set(
                fontWeightCompactTop.rawValue,
                forKey: "menuBar.fontWeightCompactTop"
            )
        }
    }
    @Published var fontWeightCompactBottom: MenuBarFontWeight {
        didSet {
            UserDefaults.standard.set(
                fontWeightCompactBottom.rawValue,
                forKey: "menuBar.fontWeightCompactBottom"
            )
        }
    }
    @Published var fontWeightNormal: MenuBarFontWeight {
        didSet {
            UserDefaults.standard.set(
                fontWeightNormal.rawValue,
                forKey: "menuBar.fontWeightNormal"
            )
        }
    }

    @Published var animateEqualizer: Bool {
        didSet {
            UserDefaults.standard.set(animateEqualizer, forKey: "menuBar.animateEqualizer")
        }
    }
    @Published var scrollLongText: Bool {
        didSet {
            UserDefaults.standard.set(scrollLongText, forKey: "menuBar.scrollLongText")
        }
    }
    @Published var animateTrackChange: Bool {
        didSet {
            UserDefaults.standard.set(animateTrackChange, forKey: "menuBar.animateTrackChange")
        }
    }
    @Published var pulseOnPlayPause: Bool {
        didSet {
            UserDefaults.standard.set(pulseOnPlayPause, forKey: "menuBar.pulseOnPlayPause")
        }
    }
    @Published var openOnHover: Bool {
        didSet {
            UserDefaults.standard.set(openOnHover, forKey: "menuBar.openOnHover")
        }
    }

    @Published var equalizerFollowsMusic: Bool {
        didSet {
            UserDefaults.standard.set(equalizerFollowsMusic, forKey: "menuBar.equalizerFollowsMusic")
        }
    }
    @Published var equalizerBarCount: Int {
        didSet {
            UserDefaults.standard.set(equalizerBarCount, forKey: "menuBar.equalizerBarCount")
        }
    }
    @Published var equalizerMirrored: Bool {
        didSet {
            UserDefaults.standard.set(equalizerMirrored, forKey: "menuBar.equalizerMirrored")
        }
    }
    @Published var equalizerBassBars: Int {
        didSet {
            UserDefaults.standard.set(equalizerBassBars, forKey: "menuBar.equalizerBassBars")
        }
    }
    @Published var equalizerBarWidth: Double {
        didSet {
            UserDefaults.standard.set(equalizerBarWidth, forKey: "menuBar.equalizerBarWidth")
        }
    }

    var isTextVisible: Bool {
        return showArtist || showTitle
    }

    init() {
        let defaults = UserDefaults.standard

        showArtist =
            defaults.object(forKey: "menuBar.showArtist") as? Bool ?? true
        showTitle =
            defaults.object(forKey: "menuBar.showTitle") as? Bool ?? true
        showIsPlayingIcon =
            defaults.object(forKey: "menuBar.showIsPlayingIcon") as? Bool
            ?? true
        showIsLikedIcon =
            defaults.object(forKey: "menuBar.showIsLikedIcon") as? Bool
            ?? true
        showAppIcon =
            defaults.object(forKey: "menuBar.showAppIcon") as? Bool ?? true
        compactView =
            defaults.object(forKey: "menuBar.compactView") as? Bool ?? true
        maxStatusItemWidth =
            defaults.object(forKey: "menuBar.maxStatusItemWidth") as? CGFloat
            ?? 150
        hideArtistWhenPaused =
            defaults.object(forKey: "menuBar.hideArtistWhenPaused") as? Bool
            ?? false
        hideTitleWhenPaused =
            defaults.object(forKey: "menuBar.hideTitleWhenPaused") as? Bool
            ?? false

        animateEqualizer =
            defaults.object(forKey: "menuBar.animateEqualizer") as? Bool ?? true
        scrollLongText =
            defaults.object(forKey: "menuBar.scrollLongText") as? Bool ?? true
        animateTrackChange =
            defaults.object(forKey: "menuBar.animateTrackChange") as? Bool ?? true
        pulseOnPlayPause =
            defaults.object(forKey: "menuBar.pulseOnPlayPause") as? Bool ?? true
        openOnHover =
            defaults.object(forKey: "menuBar.openOnHover") as? Bool ?? true

        equalizerFollowsMusic =
            defaults.object(forKey: "menuBar.equalizerFollowsMusic") as? Bool ?? true
        equalizerBarCount = min(10, max(3,
            defaults.object(forKey: "menuBar.equalizerBarCount") as? Int ?? 6))
        equalizerMirrored =
            defaults.object(forKey: "menuBar.equalizerMirrored") as? Bool ?? false
        equalizerBassBars = min(10, max(0,
            defaults.object(forKey: "menuBar.equalizerBassBars") as? Int ?? 2))
        equalizerBarWidth = min(5, max(1.5,
            defaults.object(forKey: "menuBar.equalizerBarWidth") as? Double ?? 3))

        fontWeightCompactTop = MenuBarFontWeight(
            rawValue: defaults.string(forKey: "menuBar.fontWeightCompactTop") ?? "medium"
        ) ?? .medium
        fontWeightCompactBottom = MenuBarFontWeight(
            rawValue: defaults.string(forKey: "menuBar.fontWeightCompactBottom") ?? "medium"
        ) ?? .medium
        fontWeightNormal = MenuBarFontWeight(
            rawValue: defaults.string(forKey: "menuBar.fontWeightNormal") ?? "medium"
        ) ?? .medium
    }
}
