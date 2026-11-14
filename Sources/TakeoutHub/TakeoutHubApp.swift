import SwiftUI

@main
struct TakeoutHubApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    init() {
        Darcula.prepare()
    }

    var body: some Scene {
        Window("TakeoutHub", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 940, minHeight: 640)
                .darculaWindow()
        }
        .defaultSize(width: 1180, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Downloads") {
                Button("Google Takeout") { model.pane = .browser }
                    .keyboardShortcut("1")
                Button("Downloads") { model.pane = .downloads }
                    .keyboardShortcut("2")
                Button("Fotos") { model.pane = .photos }
                    .keyboardShortcut("3")
                Divider()
                Button("Alle fortsetzen") { model.resumeAll() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(!model.canResumeAll)
                Button("Alle anhalten") { model.pauseAll() }
                    .keyboardShortcut(".", modifiers: [.command, .shift])
                    .disabled(!model.canPauseAll)
                Divider()
                Button("Seite neu laden") { Browser.shared.webView.reload() }
                    .keyboardShortcut("r")
                Button("Zurück") { Browser.shared.webView.goBack() }
                    .keyboardShortcut("[")
                Button("Vorwärts") { Browser.shared.webView.goForward() }
                    .keyboardShortcut("]")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        Darcula.applyAppearance()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Without an Xcode project the app would not start as a regular foreground app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        #if SNAPSHOT
        // Snapshot build only (build.sh never sets SNAPSHOT): renders the windows to PNG.
        Snapshot.start()
        #endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// An interrupted download resumes on the next launch, but ask anyway.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let model = AppModel.shared
        guard model.isDownloading || model.extraction != nil else { return .terminateNow }
        let alert = NSAlert()
        if model.extraction != nil {
            alert.messageText = "Es wird noch entpackt"
            alert.informativeText = "Beim Beenden bricht das Entpacken ab. Später einfach noch einmal "
                + "„Alle entpacken“ wählen – schon Entpacktes wird übersprungen."
        } else {
            alert.messageText = "Ein Download läuft noch"
            alert.informativeText = "Beim Beenden wird er unterbrochen und beim nächsten Start an derselben Stelle fortgesetzt."
        }
        alert.addButton(withTitle: "Weiterlaufen lassen")
        alert.addButton(withTitle: "Beenden")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.prepareForQuit()
    }
}
