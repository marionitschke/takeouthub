import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.pane) {
                ForEach(Pane.allCases) { pane in
                    PaneRow(pane: pane, selected: model.pane == pane)
                        .tag(pane)
                        .listRowBackground(DarculaRowBackground(selected: model.pane == pane))
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color(nsColor: Darcula.surface))
            .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 300)
        } detail: {
            switch model.pane ?? .browser {
            case .browser: BrowserView()
            case .downloads: DownloadsView()
            case .photos: PhotosView()
            }
        }
        .alert(model.notice?.title ?? "", isPresented: Binding(
            get: { model.notice != nil },
            set: { if !$0 { model.notice = nil } }
        ), presenting: model.notice) { _ in
            Button("OK", role: .cancel) {}
        } message: { notice in
            Text(notice.message)
        }
    }
}

/// Sidebar row with status, as in BackupHub.
struct PaneRow: View {
    @Environment(AppModel.self) private var model
    let pane: Pane
    /// On the selection color: white text, and white symbols unless their status color still reads.
    var selected = false

    var body: some View {
        let info = status
        HStack(spacing: 10) {
            Group {
                if info.busy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: info.symbol).foregroundStyle(symbolStyle(info.color))
                }
            }
            .font(.title2)
            .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(info.title)
                    .font(.headline)
                    .foregroundStyle(selected ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
                Text(info.text)
                    .font(.caption)
                    .foregroundStyle(selected ? AnyShapeStyle(Color.white.opacity(0.75)) : AnyShapeStyle(.secondary))
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }

    /// Warning and success keep at least 3:1 on the selection; ink, danger and grey turn white.
    private func symbolStyle(_ color: NSColor?) -> AnyShapeStyle {
        guard let color else { return selected ? AnyShapeStyle(Color.white) : AnyShapeStyle(.secondary) }
        if selected && color != Darcula.warn && color != Darcula.success { return AnyShapeStyle(Color.white) }
        return AnyShapeStyle(Color(nsColor: color))
    }

    /// `color` nil: the secondary text color.
    private var status: (title: String, text: String, symbol: String, color: NSColor?, busy: Bool) {
        switch pane {
        case .browser:
            let browser = Browser.shared
            return ("Google Takeout", browser.host ?? "Anmelden und Export anfordern",
                    "globe", Darcula.ink, false)
        case .downloads:
            let items = model.items
            if items.isEmpty { return ("Downloads", "Noch nichts geladen", "arrow.down.circle", nil, false) }
            let done = items.filter { $0.state == .done }.count
            let counter = "\(done) von \(items.count) fertig"
            if items.contains(where: { $0.state == .needsLogin }) {
                return ("Downloads", "Anmeldung nötig · \(counter)", "exclamationmark.triangle.fill", Darcula.warn, false)
            }
            if items.contains(where: { $0.state == .failed }) {
                return ("Downloads", "Fehler · \(counter)", "xmark.octagon.fill", Darcula.danger, false)
            }
            if model.isDownloading {
                let rate = model.speed.map { " · \(Fmt.speed($0))" } ?? ""
                return ("Downloads", counter + rate, "arrow.down.circle", Darcula.ink, true)
            }
            if items.contains(where: { $0.state == .waiting }) {
                return ("Downloads", (model.online ? "Wartet auf neuen Versuch" : "Keine Internetverbindung") + " · \(counter)",
                        "wifi.exclamationmark", Darcula.warn, false)
            }
            if done == items.count { return ("Downloads", "Alle \(done) fertig", "checkmark.circle.fill", Darcula.success, false) }
            return ("Downloads", counter + " · angehalten", "pause.circle", nil, false)
        case .photos:
            if let extraction = model.extraction {
                let text = extraction.count > 0 ? "Entpacke \(extraction.index) von \(extraction.count) …" : extraction.phase
                return ("Fotos", text, "photo.on.rectangle", Darcula.ink, true)
            }
            let open = model.extractable.count
            if open > 0 {
                return ("Fotos", "\(open) \(open == 1 ? "Archiv" : "Archive") bereit zum Entpacken",
                        "shippingbox.fill", Darcula.warn, false)
            }
            if model.items.contains(where: { $0.extractedAt != nil }) {
                return ("Fotos", "Entpackt in \(Fmt.path(model.settings.photosURL))", "checkmark.circle.fill", Darcula.success, false)
            }
            return ("Fotos", "Archive entpacken, Datum übernehmen", "photo.on.rectangle", nil, false)
        }
    }
}

/// Folder row with free space and buttons, for archives and photos.
struct FolderRow: View {
    @Environment(AppModel.self) private var model
    let label: String
    let url: URL
    let photos: Bool
    /// Space needed (e.g. the rest of the open downloads); shows a warning if it exceeds the free space.
    var needed: Int64 = 0

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Text(Fmt.path(url))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 12)
            if let free = Store.freeSpace(url) {
                let short = needed > free
                Label("\(Fmt.size(free)) frei", systemImage: short ? "exclamationmark.triangle.fill" : "internaldrive")
                    .font(.caption)
                    .foregroundStyle(short ? Color(nsColor: Darcula.warn) : .secondary)
                    .help(short ? "Für die offenen Downloads fehlen \(Fmt.size(needed - free))." : "Freier Platz auf diesem Laufwerk")
            }
            Button("Ändern …") { model.chooseFolder(photos: photos) }
            Button {
                model.openFolder(url)
            } label: {
                Image(systemName: "arrow.up.forward.app")
            }
            .help("Im Finder öffnen")
        }
    }
}
