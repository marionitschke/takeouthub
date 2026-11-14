import SwiftUI

struct BrowserView: View {
    @Environment(AppModel.self) private var model
    @State private var address = ""
    @State private var confirmSignOut = false
    private let browser = Browser.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    browser.webView.goBack()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(!browser.canGoBack)
                .help("Zurück (⌘[)")
                Button {
                    browser.webView.goForward()
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(!browser.canGoForward)
                .help("Vorwärts (⌘])")
                Button {
                    if browser.isLoading { browser.webView.stopLoading() } else { browser.webView.reload() }
                } label: {
                    Image(systemName: browser.isLoading ? "xmark" : "arrow.clockwise")
                }
                .help(browser.isLoading ? "Laden stoppen" : "Neu laden (⌘R)")

                TextField("Adresse", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { browser.open(address) }
                    .frame(minWidth: 200)

                Button {
                    browser.load(Browser.createURL)
                } label: {
                    Label("Export erstellen", systemImage: "plus.rectangle.on.folder")
                }
                .help("Takeout mit nur Google Fotos öffnen")
                Button {
                    browser.load(Browser.manageURL)
                } label: {
                    Label("Exporte verwalten", systemImage: "tray.and.arrow.down")
                }
                .help("Fertige Exporte mit den Download-Knöpfen")
                Button {
                    confirmSignOut = true
                } label: {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                }
                .help("Abmelden: Cookies dieses Browsers löschen")
            }
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            HStack(spacing: 8) {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                Text("Bei einem fertigen Export einfach auf „Herunterladen“ klicken: TakeoutHub lädt die Datei selbst "
                     + "und macht nach Abbrüchen an derselben Stelle weiter.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            Divider()
            WebViewHost(webView: browser.webView)
        }
        .overlay(alignment: .bottom) {
            if let banner = model.banner {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(.white)
                    Text(banner.text).foregroundStyle(.white)
                    Button("Zu den Downloads") {
                        model.banner = nil
                        model.pane = .downloads
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.white.opacity(0.25))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color(nsColor: Darcula.main).gradient, in: Capsule())
                .shadow(radius: 8, y: 3)
                .padding(.bottom, 20)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.banner)
        .navigationTitle(browser.title.isEmpty ? "Google Takeout" : browser.title)
        .onAppear { address = browser.address }
        .onChange(of: browser.address) { _, new in address = new }
        .confirmationDialog("Von Google abmelden?", isPresented: $confirmSignOut) {
            Button("Abmelden", role: .destructive) {
                Task { await browser.signOut() }
            }
        } message: {
            Text("Löscht Cookies und Website-Daten des eingebauten Browsers. Laufende Downloads brauchen danach eine neue Anmeldung.")
        }
    }
}
