import SwiftUI

/// Done.md brand palette. Single source of truth for the brand accent so every
/// call site (outline selection, future accents) refers to one value — recolor
/// the whole app by editing here.
extension Color {
    /// Brand green ("KV 绿"). First calibration pass against the brand spec —
    /// tune this one constant on-device, everything that reads `Color.brandGreen`
    /// updates. A slightly deeper, less neon green than the old placeholder so it
    /// reads as an accent, not a highlighter.
    ///
    /// Note: this is the `.system` theme's accent. Other writing themes carry
    /// their own accent (see `WritingTheme.accentColor`), so prefer reading the
    /// active theme's accent at call sites that should follow the theme.
    static let brandGreen = Color(red: 0.11, green: 0.66, blue: 0.44)
}

/// Writing background theme (Phase 5 S8, #80). A per-app display preference that
/// re-skins the whole editor window — background, accent color, and (via the
/// `data-theme` bridge) the syntax coloring in both the Markdown 源 pane and the
/// Visual code blocks — for writing mood.
///
/// **铁律 (story 34)**: display-only, NEVER written to `.md` disk. Lives entirely
/// in `@AppStorage`, so files stay byte-clean and other editors are unaffected.
/// No frontmatter, no serialization path.
///
/// Three themes (converged from the initial four):
/// - `.system` — follows system light/dark, KV-green accent. Default; reproduces
///   the pre-S8 look with zero regression (no wash, no forced scheme).
/// - `.paper` — warm cream "paper" with a paper-grain texture and an orange
///   accent; syntax coloring shifts to a warm palette (no cold blues).
/// - `.night` — a deep blue-tinted dark (bluer than system dark, Cursor-like)
///   with a desaturated cyan accent and low-saturation CLI-style syntax coloring.
enum WritingTheme: String, CaseIterable, Identifiable {
    /// Follows system light/dark. Default. Reproduces the transparent,
    /// material-only look Done.md had before S8.
    case system
    /// Warm cream "paper" —泛黄暖底 + 纸张颗粒, orange accent, warm syntax.
    case paper
    /// 赛博夜色 — deep blue-tinted dark, desaturated cyan accent, CLI-cool syntax.
    case night

    var id: String { rawValue }

    /// Chinese label for the 写作背景 menu.
    var displayName: String {
        switch self {
        case .system: return "跟随系统"
        case .paper:  return "纸质"
        case .night:  return "赛博夜色"
        }
    }

    /// The base color painted behind the whole window. For `.system` this is the
    /// standard text-background color, which SwiftUI resolves per light/dark, so
    /// the window looks exactly as it did before S8. The others are fixed.
    var backgroundColor: Color {
        switch self {
        case .system: return Color(nsColor: .textBackgroundColor)
        // Warm off-white à la Claude's brand cream — low saturation, hue nudged
        // toward warm red/terracotta rather than yellow, close to white so it
        // reads as paper stock, not parchment. The grain (CSS) rides on top.
        case .paper:  return Color(red: 0.973, green: 0.957, blue: 0.933)
        // Deep blue-tinted charcoal — bluer + a touch darker than the system dark
        // surface, echoing the referenced Cursor palette.
        case .night:  return Color(red: 0.09, green: 0.11, blue: 0.15)
        }
    }

    /// Theme accent. `.system` = KV 绿; `.paper` = warm orange; `.night` = a
    /// desaturated cyan that reads "cool CLI" without glowing. Outline selection
    /// (and future accents) read this so the accent follows the theme.
    var accentColor: Color {
        switch self {
        case .system: return .brandGreen
        // Claude-like terracotta/clay — warm red-orange, not a yellow-orange.
        case .paper:  return Color(red: 0.80, green: 0.40, blue: 0.27)
        case .night:  return Color(red: 0.38, green: 0.70, blue: 0.75)
        }
    }

    /// A translucent wash laid over the system outline sidebar so it picks up the
    /// theme tint too (the native `NavigationSplitView` sidebar material samples
    /// the desktop behind the window, not our in-window color layer, so it won't
    /// tint on its own). `.system` returns `.clear` → no wash, no regression.
    var sidebarWash: Color {
        switch self {
        case .system: return .clear
        default:      return backgroundColor.opacity(0.5)
        }
    }

    /// True when this theme forces a dark surface regardless of the system
    /// appearance, so the window flips its `colorScheme` and keeps text / chrome
    /// legible. `.paper` is a light surface even in system dark mode → forces
    /// light so titlebar/menus stay dark-on-light.
    var forcedColorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .paper:  return .light
        case .night:  return .dark
        }
    }

    /// Value pushed to the webviews' `<html data-theme="…">` so the CSS can pick
    /// the matching syntax palette. `.system` uses no attribute → the CSS falls
    /// back to its `prefers-color-scheme` light/dark rules (pre-S8 behavior).
    var webDataThemeValue: String? {
        switch self {
        case .system: return nil
        case .paper:  return "paper"
        case .night:  return "night"
        }
    }
}
