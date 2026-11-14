// For scripts/snapshot.sh only: saves images of the windows and quits the app.
// Runs with TAKEOUTHUB_HOME (sample state, non-persistent browser, no Google requests).
// screencapture needs the Screen Recording permission, so the app draws its own window. Glass
// surfaces (sidebar, alerts) and WebKit content stay empty; the sidebar is also drawn via
// ImageRenderer.
import AppKit
import SwiftUI

@MainActor
enum Snapshot {
    static var dir = ""
    static var counter = 0

    static func capture(_ label: String) {
        for (index, window) in NSApp.windows.enumerated() where window.isVisible {
            guard let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let url = URL(fileURLWithPath: "\(dir)/\(String(format: "%02d", counter))-\(label)-w\(index).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
        counter += 1
    }

    /// README image: the window at 2x in sRGB. Glass (sidebar, traffic lights) stays empty in
    /// cacheDisplay, so the sidebar and the traffic lights are drawn by hand on top.
    @MainActor
    static func readmeImage(model: AppModel) {
        guard let window = NSApp.windows.first(where: { $0.isVisible }),
              let view = window.contentView?.superview ?? window.contentView else { return }
        let size = view.bounds.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2),
                                         pixelsHigh: Int(size.height * 2), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = size
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/screenshot-raw.png"))

        let rows = VStack(alignment: .leading, spacing: 8) {
            ForEach(Pane.allCases) { pane in
                PaneRow(pane: pane, selected: pane == model.pane)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .frame(width: 208, alignment: .leading)
                    .background(pane == model.pane ? Color(nsColor: Darcula.selection) : .clear,
                                in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .foregroundStyle(Color(nsColor: Darcula.text), Color(nsColor: Darcula.muted), Color(nsColor: Darcula.faint))
        .environment(\.colorScheme, .dark)
        .environment(model)
        let renderer = ImageRenderer(content: rows)
        renderer.scale = 2

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let sidebar = NSRect(x: 0, y: 0, width: 240, height: size.height)
        Darcula.background.setFill()
        sidebar.fill()
        let panel = NSBezierPath(roundedRect: sidebar.insetBy(dx: 8, dy: 8), xRadius: 16, yRadius: 16)
        Darcula.surface.setFill()
        panel.fill()
        Darcula.border.setStroke()
        panel.lineWidth = 0.5
        panel.stroke()
        let lights: [(NSWindow.ButtonType, UInt32)] = [(.closeButton, 0xFF5F57), (.miniaturizeButton, 0xFEBC2E),
                                                       (.zoomButton, 0x28C840)]
        for (index, (type, hex)) in lights.enumerated() {
            let frame = window.standardWindowButton(type).map { $0.convert($0.bounds, to: view) }
                ?? NSRect(x: 20 + CGFloat(index) * 22, y: size.height - 31, width: 12, height: 12)
            let side = min(frame.width, frame.height)
            Darcula.color(hex).setFill()
            NSBezierPath(ovalIn: NSRect(x: frame.midX - side / 2, y: frame.midY - side / 2, width: side, height: side)).fill()
        }
        if let symbol = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular)) {
            let tinted = NSImage(size: symbol.size, flipped: false) { rect in
                symbol.draw(in: rect)
                Darcula.muted.set()
                rect.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(at: NSPoint(x: 204, y: size.height - 25 - symbol.size.height / 2), from: .zero,
                        operation: .sourceOver, fraction: 1)
        }
        if let image = renderer.nsImage {
            image.draw(in: NSRect(x: 16, y: size.height - 52 - image.size.height, width: image.size.width,
                                  height: image.size.height))
        }
        NSGraphicsContext.restoreGraphicsState()
        let srgb = rep.converting(to: .sRGB, renderingIntent: .default) ?? rep
        try? srgb.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/screenshot.png"))
    }

    /// The real sidebar list on its own: its glass container stays empty in the window image, the
    /// list view itself does not – shows the selected row as the app draws it.
    static func sidebarList() {
        guard let window = NSApp.windows.first(where: { $0.isVisible }), let frame = window.contentView?.superview else { return }
        func tables(_ view: NSView) -> [NSTableView] {
            view.subviews.flatMap { ($0 as? NSTableView).map { [$0] } ?? tables($0) }
        }
        guard let table = tables(frame).min(by: { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }),
              let rep = table.bitmapImageRepForCachingDisplay(in: table.bounds) else { return }
        window.makeFirstResponder(table)
        table.cacheDisplay(in: table.bounds, to: rep)
        let srgb = rep.converting(to: .sRGB, renderingIntent: .default) ?? rep
        try? srgb.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/sidebar-list.png"))
    }

    /// Started from a script, the app rarely gets the focus; draw the window as the active key window.
    static func pretendActive(_ window: NSWindow) {
        let getters: [(AnyClass, String)] = [(NSApplication.self, "isActive")]
            + ["isKeyWindow", "isMainWindow", "_hasActiveAppearance", "_hasActiveAppearanceIgnoringKeyFocus",
               "_hasKeyAppearance", "_hasMainAppearance", "hasKeyAppearance", "hasMainAppearance"].map { (NSWindow.self, $0) }
        for (type, name): (AnyClass, String) in getters {
            guard let method = class_getInstanceMethod(type, NSSelectorFromString(name)) else { continue }
            let always: @convention(block) (AnyObject) -> Bool = { _ in true }
            method_setImplementation(method, imp_implementationWithBlock(always))
        }
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        NotificationCenter.default.post(name: NSWindow.didBecomeMainNotification, object: window)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        func invalidate(_ view: NSView) {
            view.needsDisplay = true
            view.subviews.forEach(invalidate)
        }
        if let frame = window.contentView?.superview { invalidate(frame) }
    }

    static func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    static func start() {
        guard AppPaths.isTest, let target = ProcessInfo.processInfo.environment["TAKEOUTHUB_SNAPSHOT"] else { return }
        dir = target
        Task { @MainActor in
            let model = AppModel.shared
            // A plain local page instead of Google.
            Browser.shared.webView.loadHTMLString(
                "<html><body style='font:15px -apple-system;padding:40px;background:#2B2B2B;color:#C4C7CA'><h2>Google Takeout</h2>"
                    + "<p>(Platzhalter im Prüf-Build)</p></body></html>", baseURL: nil)
            await pause(4)
            model.pane = .downloads
            if let window = NSApp.windows.first(where: { $0.isVisible }) { pretendActive(window) }
            await pause(1.5)
            capture("downloads")
            readmeImage(model: model)
            sidebarList()
            model.pane = .photos
            await pause(1)
            capture("fotos")
            model.settings.sortIntoMonths = true
            await pause(0.5)
            capture("fotos-monatsordner")
            model.pane = .browser
            model.showBanner("takeout-20261105T081512Z-004.zip steht in der Warteschlange.")
            await pause(1)
            capture("browser")

            let rows = VStack(alignment: .leading, spacing: 8) {
                ForEach(Pane.allCases) { PaneRow(pane: $0, selected: $0 == .photos) }
            }
            .padding(12).frame(width: 260).background(Color(nsColor: Darcula.surface))
            .foregroundStyle(Color(nsColor: Darcula.text), Color(nsColor: Darcula.muted), Color(nsColor: Darcula.faint))
            .environment(\.colorScheme, .dark).environment(model)
            let renderer = ImageRenderer(content: rows)
            renderer.scale = 2
            if let tiff = renderer.nsImage?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/sidebar.png"))
            }

            // Empty state: instructions
            for item in model.items { model.remove(item.id, trash: false) }
            model.pane = .downloads
            await pause(1)
            capture("anleitung")

            for line in model.logLines.suffix(8) { print(line) }
            fflush(stdout)
            model.prepareForQuit()
            exit(0)
        }
    }
}
