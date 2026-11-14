import SwiftUI

struct PhotosView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let archives = model.items.filter { $0.state == .done && $0.isArchive }
        let open = model.extractable
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox {
                    FolderRow(label: "Fotos werden entpackt nach", url: model.settings.photosURL, photos: true,
                              needed: open.reduce(0) { $0 + ($1.totalBytes ?? 0) })
                        .padding(6)
                } label: {
                    Text("Zielordner").font(.headline)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        if archives.isEmpty {
                            Text("Noch keine fertigen Archive. Sobald ein Download fertig ist, erscheint er hier.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(archives) { item in
                                ArchiveRow(item: item)
                                if item.id != archives.last?.id { Divider() }
                            }
                        }
                        if let extraction = model.extraction {
                            VStack(alignment: .leading, spacing: 6) {
                                if extraction.total > 0 {
                                    ProgressView(value: Double(extraction.done), total: Double(max(extraction.total, 1)))
                                } else {
                                    ProgressView().progressViewStyle(.linear)
                                }
                                Text(extractionText(extraction))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.top, 4)
                        }
                        HStack(alignment: .firstTextBaseline, spacing: 16) {
                            Button {
                                model.extractAll()
                            } label: {
                                Label(open.isEmpty ? "Alle entpacken" : "Alle entpacken (\(open.count))",
                                      systemImage: "shippingbox")
                            }
                            .primaryAction()
                            .disabled(open.isEmpty || model.extraction != nil)
                            VStack(alignment: .leading, spacing: 6) {
                                Toggle("Fotos in Monatsordner sortieren", isOn: $model.settings.sortIntoMonths)
                                    .help("Nach dem Entpacken kommt jedes Foto nach Aufnahmemonat in einen Unterordner "
                                          + "seines Albums, z. B. „Fotos von 2019/03“.")
                                Toggle("Archiv danach in den Papierkorb legen", isOn: $model.settings.trashAfterExtract)
                                    .help("Spart Platz. Ohne Archiv lässt sich ein Teil nicht noch einmal entpacken.")
                            }
                        }
                        .padding(.top, 4)
                        Text(extractionHint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(6)
                } label: {
                    Text("Archive entpacken").font(.headline)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Google legt das Aufnahmedatum in .json-Begleitdateien neben die Fotos. TakeoutHub setzt "
                             + "damit „Erstellt“ und „Geändert“ der Fotos und Videos – das passiert nach dem Entpacken "
                             + "automatisch\(model.settings.sortIntoMonths ? ", danach wird in Monatsordner sortiert" : ""). "
                             + "Der Inhalt der Dateien und die JSON-Dateien bleiben unverändert.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 12) {
                            Button {
                                model.applyDates()
                            } label: {
                                Label(model.settings.sortIntoMonths ? "Aufnahmedatum übernehmen und einsortieren"
                                                                    : "Aufnahmedatum jetzt übernehmen",
                                      systemImage: "calendar.badge.clock")
                            }
                            .disabled(model.extraction != nil)
                            if let last = model.lastDates {
                                Text(last).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(6)
                } label: {
                    Text("Aufnahmedatum").font(.headline)
                }
            }
            .padding(20)
            .groupBoxStyle(CardGroupBoxStyle())
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Fotos")
    }

    private var extractionHint: String {
        guard model.settings.sortIntoMonths else {
            return "Alle Teile landen zusammengeführt im Zielordner (Unterordner „Google Fotos“, darin die Alben "
                + "und „Fotos von JJJJ“). Was dort schon liegt, wird nicht überschrieben."
        }
        return "Alle Teile landen zusammengeführt im Zielordner (Unterordner „Google Fotos“). Danach kommen die Fotos "
            + "und Videos jedes Albums und jedes „Fotos von JJJJ“ nach Aufnahmemonat in die Unterordner 01 bis 12, "
            + "z. B. „Fotos von 2019/03“, Alben aus mehreren Jahren mit dem Jahr davor („Urlaub/2019/12“). Die "
            + ".json-Begleitdatei wandert mit. Überschrieben wird nichts, Fotos ohne Aufnahmedatum bleiben liegen."
    }

    private func extractionText(_ status: ExtractionStatus) -> String {
        guard status.count > 0 else { return status.phase }
        var text = "\(status.archive) (\(status.index) von \(status.count)) · \(status.phase)"
        if status.total > 0 { text += " \(Fmt.count(status.done)) von \(Fmt.count(status.total)) Dateien" }
        return text
    }
}

struct ArchiveRow: View {
    @Environment(AppModel.self) private var model
    let item: DownloadItem

    var body: some View {
        let exists = FileManager.default.fileExists(atPath: item.fileURL.path)
        HStack(spacing: 10) {
            Image(systemName: item.extractedAt != nil ? "checkmark.circle.fill" : "shippingbox")
                .foregroundStyle(item.extractedAt != nil ? Color(nsColor: Darcula.success) : Color.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.fileName).lineLimit(1).truncationMode(.middle)
                Text(status(exists: exists)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if exists {
                Button {
                    model.reveal(item)
                } label: {
                    Image(systemName: "magnifyingglass.circle")
                }
                .buttonStyle(.borderless)
                .font(.title3)
                .help("Im Finder zeigen")
            }
        }
    }

    private func status(exists: Bool) -> String {
        let size = Fmt.size(item.totalBytes ?? item.receivedBytes)
        if let date = item.extractedAt {
            return "\(size) · entpackt \(Fmt.moment(date))\(exists ? "" : " · Archiv entfernt")"
        }
        return exists ? "\(size) · bereit" : "\(size) · Datei fehlt"
    }
}

/// A card as in DiaryHub: the label above a surface with a fine border.
struct CardGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            configuration.label
            configuration.content
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: Darcula.surface), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: Darcula.border), lineWidth: 1))
        }
    }
}
