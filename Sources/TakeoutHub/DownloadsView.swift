import SwiftUI

struct DownloadsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            DownloadsHeader()
                .padding(16)
            Divider()
            if model.items.isEmpty {
                GuideView()
            } else {
                List {
                    ForEach(model.items) { item in
                        DownloadRow(item: item)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
            Divider()
            LogPanel()
                .frame(height: 150)
        }
        .navigationTitle("Downloads")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.resumeAll()
                } label: {
                    Label("Alle fortsetzen", systemImage: "play.fill")
                }
                .help("Alle angehaltenen und fehlgeschlagenen Downloads fortsetzen (⇧⌘R)")
                .disabled(!model.canResumeAll)
                Button {
                    model.pauseAll()
                } label: {
                    Label("Alle anhalten", systemImage: "pause.fill")
                }
                .help("Alle Downloads anhalten (⇧⌘.)")
                .disabled(!model.canPauseAll)
            }
        }
    }
}

struct DownloadsHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 10) {
            if !model.items.isEmpty {
                let done = model.items.filter { $0.state == .done }.count
                let total = model.totalBytes
                HStack(alignment: .firstTextBaseline) {
                    Text("\(done) von \(model.items.count) \(model.items.count == 1 ? "Datei" : "Dateien") geladen")
                        .font(.title3.weight(.semibold))
                    Text("\(Fmt.size(model.receivedBytes)) von \(Fmt.size(total))")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(statusLine)
                        .foregroundStyle(model.online ? Color.secondary : Color(nsColor: Darcula.warn))
                }
                ProgressView(value: total > 0 ? min(1, Double(model.receivedBytes) / Double(total)) : 0)
            }
            FolderRow(label: "Archive werden gespeichert in", url: model.settings.archiveURL, photos: false,
                      needed: model.remainingBytes)
            Toggle("Ruhezustand verhindern, solange geladen wird", isOn: $model.settings.keepAwake)
                .help("Der Mac schläft dann nicht von selbst ein. Zugeklappt im Akkubetrieb schläft er trotzdem.")
        }
    }

    private var statusLine: String {
        if !model.online { return "Keine Internetverbindung – geht weiter, sobald sie zurück ist" }
        guard model.isDownloading else {
            return model.items.contains(where: { $0.isActive }) ? "Wartet auf neuen Versuch" : ""
        }
        var parts: [String] = []
        if let speed = model.speed { parts.append(Fmt.speed(speed)) }
        if let eta = model.eta { parts.append("noch ca. \(Fmt.duration(eta))") }
        return parts.isEmpty ? "Verbindung wird aufgebaut …" : parts.joined(separator: " · ")
    }
}

struct DownloadRow: View {
    @Environment(AppModel.self) private var model
    let item: DownloadItem
    @State private var confirmRemove = false

    var body: some View {
        HStack(spacing: 12) {
            stateIcon
                .font(.title2)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.fileName)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if item.state != .done {
                    ProgressView(value: item.fraction ?? 0)
                        .tint(item.state == .running ? Color(nsColor: Darcula.ink) : .secondary)
                }
                detail
                    .font(.caption)
                    .foregroundStyle(detailColor)
                    .lineLimit(3)
            }
            Spacer(minLength: 12)
            actions
        }
        .padding(.vertical, 6)
        .confirmationDialog("\(item.fileName) entfernen?", isPresented: $confirmRemove) {
            Button("Nur aus der Liste entfernen") { model.remove(item.id, trash: false) }
            Button(item.state == .done ? "Auch die Datei in den Papierkorb legen" : "Auch die Teildatei in den Papierkorb legen",
                   role: .destructive) {
                model.remove(item.id, trash: true)
            }
        } message: {
            Text(item.state == .done
                 ? "Die Datei bleibt im Ordner, wenn du sie nur aus der Liste entfernst."
                 : "Ohne Teildatei beginnt ein neuer Download dieses Teils wieder bei null.")
        }
    }

    @ViewBuilder private var stateIcon: some View {
        switch item.state {
        case .running: ProgressView().controlSize(.small)
        case .queued: Image(systemName: "clock").foregroundStyle(.secondary)
        case .paused: Image(systemName: "pause.circle").foregroundStyle(.secondary)
        case .waiting: Image(systemName: "wifi.exclamationmark").foregroundStyle(Color(nsColor: Darcula.warn))
        case .needsLogin:
            Image(systemName: "person.crop.circle.badge.exclamationmark").foregroundStyle(Color(nsColor: Darcula.warn))
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(Color(nsColor: Darcula.danger))
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Color(nsColor: Darcula.success))
        }
    }

    private var amount: String {
        if let total = item.totalBytes { return "\(Fmt.size(item.receivedBytes)) von \(Fmt.size(total))" }
        return Fmt.size(item.receivedBytes)
    }

    @ViewBuilder private var detail: some View {
        switch item.state {
        case .running:
            let rate = model.speed.map { " · \(Fmt.speed($0))" } ?? ""
            let rest: String = {
                guard let speed = model.speed, speed > 0, let total = item.totalBytes else { return "" }
                return " · noch ca. \(Fmt.duration(Double(total - item.receivedBytes) / speed))"
            }()
            Text(amount + rate + rest)
        case .queued:
            Text("Wartet · \(amount)")
        case .paused:
            Text("Angehalten · \(amount)")
        case .waiting:
            if !model.online {
                Text("\(item.message ?? "Unterbrochen") · \(amount) · geht weiter, sobald das Internet zurück ist")
            } else if let date = model.retryAt[item.id], date > Date() {
                Text("\(item.message ?? "Unterbrochen") · \(amount) · neuer Versuch in \(Text(date, style: .timer))")
            } else {
                Text("\(item.message ?? "Unterbrochen") · \(amount) · neuer Versuch gleich")
            }
        case .needsLogin, .failed:
            Text("\(item.message ?? "Fehler") · \(amount)")
        case .done:
            let finished = item.finishedAt.map { " · fertig \(Fmt.moment($0))" } ?? ""
            let missing = !FileManager.default.fileExists(atPath: item.fileURL.path)
            let extracted = item.extractedAt != nil ? (missing ? " · entpackt, Archiv entfernt" : " · entpackt") : ""
            Text(Fmt.size(item.totalBytes ?? item.receivedBytes) + finished + extracted
                 + (missing && item.extractedAt == nil ? " · Datei fehlt" : ""))
        }
    }

    private var detailColor: Color {
        switch item.state {
        case .needsLogin, .waiting: return Color(nsColor: Darcula.warn)
        case .failed: return Color(nsColor: Darcula.danger)
        default: return .secondary
        }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 4) {
            switch item.state {
            case .running, .queued, .waiting:
                iconButton("pause.circle", "Anhalten") { model.pause(item.id) }
            case .paused:
                iconButton("play.circle", "Fortsetzen") { model.resume(item.id) }
            case .needsLogin, .failed:
                iconButton("arrow.clockwise.circle", "Erneut versuchen") { model.resume(item.id) }
            case .done:
                EmptyView()
            }
            iconButton("magnifyingglass.circle", "Im Finder zeigen") { model.reveal(item) }
            iconButton("xmark.circle", "Entfernen …") { confirmRemove = true }
        }
        .font(.title2)
    }

    private func iconButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

/// Instructions shown until the first download.
struct GuideView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("So kommen deine Google Fotos auf den Mac")
                    .font(.title2.weight(.semibold))
                step(1, "Anmelden",
                     "Unter „Google Takeout“ mit deinem Google-Konto anmelden. Die Anmeldung bleibt in TakeoutHub gespeichert.")
                step(2, "Export anfordern",
                     "„Export erstellen“ öffnet Takeout mit nur Google Fotos. Dann „Nächster Schritt“, Übertragungsart "
                        + "„Download-Link per E-Mail“, einmaliger Export, Dateityp .zip und eine Dateigröße wählen. "
                        + "Große Teile (z. B. 50 GB) sind kein Problem, weil TakeoutHub nach Abbrüchen weitermacht.")
                step(3, "Warten",
                     "Google stellt den Export zusammen – je nach Menge Stunden bis Tage. Die Mail kündigt an, wenn er fertig ist.")
                step(4, "Herunterladen",
                     "„Exporte verwalten“ öffnen und bei jedem Teil auf „Herunterladen“ klicken (ggf. Passwort bestätigen). "
                        + "TakeoutHub übernimmt jeden Teil und lädt einen nach dem anderen.")
                step(5, "Entpacken",
                     "Unter „Fotos“ die fertigen Archive in einen Ordner entpacken; das Aufnahmedatum wird dabei aus "
                        + "Googles Begleitdateien übernommen.")
                Button("Zu Google Takeout") { model.pane = .browser }
                    .primaryAction()
                    .controlSize(.large)
            }
            .padding(28)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func step(_ number: Int, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Color(nsColor: Darcula.main), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct LogPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Protokoll").font(.headline)
                Spacer()
                Button("Öffnen") { model.openLog() }
                    .controlSize(.small)
                    .help(Fmt.path(AppPaths.logFile))
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(model.logLines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(line.contains("WARNUNG") ? Color(nsColor: Darcula.warn) : Color.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .padding(8)
                }
                .background(Color(nsColor: Darcula.surface), in: RoundedRectangle(cornerRadius: 6))
                .onAppear { proxy.scrollTo(model.logLines.count - 1, anchor: .bottom) }
                .onChange(of: model.logLines.count) { _, count in proxy.scrollTo(count - 1, anchor: .bottom) }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
