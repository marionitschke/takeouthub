import AppKit
import SwiftUI

/// The look of all hub apps: Darcula as in WebStorm and DiaryHub – always dark, neutral grey
/// surfaces, a grey accent for controls and selections; the app's main color only marks primary
/// actions and its own content. Mirrors `shared/Darcula.swift` in StudioHub.
enum Darcula {
    /// Window, lists.
    static let background = color(0x2B2B2B)
    /// Panels, cards, sidebar.
    static let surface = color(0x313335)
    /// Controls and raised areas on a surface; also the row lines of lists.
    static let raised = color(0x3C3F41)
    static let border = color(0x4B4F52)
    static let text = color(0xC4C7CA)
    static let muted = color(0x8F9395)
    static let faint = color(0x65696C)
    static let accent = color(0x8A8E91)
    static let danger = color(0xF26B6B)
    /// Filled danger buttons and markers, with white text.
    static let dangerFill = color(0xB91C1C)
    static let warn = color(0xF59E0B)
    static let success = color(0x3FBF63)

    /// TakeoutHub's main color (raspberry), as in its icon: primary buttons, its own content.
    static let main = color(0xC8356A)
    /// The main color lightened for symbols and text on the dark background.
    static let ink = color(0xE5749D)
    /// Selected sidebar rows and segments, with white text: 55 % main color on the surface grey.
    /// The graphite accent's own selection is a light grey that left light text at about 2:1.
    static let selection = main.blended(withFraction: 0.45, of: surface)!

    static func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    /// Must run before `NSApplication.shared` exists – AppKit reads the accent color once when it starts.
    /// Without Xcode there is no asset catalog for an app accent color; the argument domain is not
    /// saved and wins over the system setting, so the app's controls turn graphite.
    static func prepare() {
        let defaults = UserDefaults.standard
        var arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments["AppleAccentColor"] = -1
        arguments["AppleAquaColorVariant"] = 6
        arguments["AppleHighlightColor"] = "0.847059 0.847059 0.862745 Graphite"
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }

    /// Dark for every window, sheet, alert and menu, whatever the system uses.
    @MainActor
    static func applyAppearance() {
        NSApp.appearance = NSAppearance(named: .darkAqua)
    }
}

extension View {
    /// Darcula for a whole window: its background, and the palette's text colors as the primary,
    /// secondary and tertiary foreground styles.
    func darculaWindow() -> some View {
        foregroundStyle(Color(nsColor: Darcula.text), Color(nsColor: Darcula.muted), Color(nsColor: Darcula.faint))
            .modifier(DarculaWindowBackground())
    }

    /// A primary action in the app's main color with white text, like DiaryHub's primary buttons.
    func primaryAction() -> some View {
        buttonStyle(.borderedProminent)
            .tint(Color(nsColor: Darcula.main))
            .foregroundStyle(.white)
    }

    /// A segmented picker whose selected segment uses the selection color (white text).
    func darculaSegments() -> some View {
        pickerStyle(.segmented).tint(Color(nsColor: Darcula.selection))
    }
}

/// Row background for sidebar lists: covers the system's light-grey highlight with the selection
/// color, so the row's text can turn white.
struct DarculaRowBackground: View {
    let selected: Bool

    var body: some View {
        ZStack {
            Color(nsColor: Darcula.surface)
            if selected {
                RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: Darcula.selection)).padding(.horizontal, 6)
            }
        }
    }
}

/// `containerBackground(_:for: .window)` needs macOS 15; macOS 14 colors the NSWindow itself.
private struct DarculaWindowBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.containerBackground(Color(nsColor: Darcula.background), for: .window)
        } else {
            content.background(WindowAccessor { window in
                window.backgroundColor = Darcula.background
                window.titlebarAppearsTransparent = true
            })
        }
    }
}

private struct WindowAccessor: NSViewRepresentable {
    let configure: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { if let window = view.window { configure(window) } }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}
