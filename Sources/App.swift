import SwiftUI
import QuickLook

@main
struct EntpackerApp: App {
    @StateObject private var files = Files()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                FolderView(dir: docs).navigationDestination(for: URL.self) { FolderView(dir: $0) }
            }
            .environmentObject(files)
            .onOpenURL { files.receive([$0]) }
        }
    }
}

/// Eine Meldung oder Eingabe, die als Hinweisfenster erscheint.
struct Hint {
    enum Kind { case info, password, rename, folder, zip }
    let title: String
    let text: String
    var kind: Kind = .info
}

struct FileRow: Identifiable {
    let url: URL
    let isDir: Bool
    let size: Int64
    let date: Date
    var id: URL { url }
}

enum SortKey: String, CaseIterable { case name = "Name", date = "Datum", size = "Größe" }

struct FolderView: View {
    let dir: URL
    @EnvironmentObject private var fs: Files
    @AppStorage("sort") private var sort: SortKey = .name
    @AppStorage("deleteAfter") private var deleteAfter = false
    @State private var items: [FileRow] = []
    @State private var query = ""
    @State private var busy = false
    @State private var progress: Double?
    @State private var alert: Hint?
    @State private var quick: URL?
    @State private var video: URL?
    @State private var moving: MoveJob?
    @State private var targets: [URL] = []   // worauf sich das offene Hinweisfenster bezieht
    @State private var input = ""
    @State private var password = ""
    @State private var editing = false
    @State private var selection = Set<URL>()

    private var shown: [FileRow] {
        let found = query.isEmpty ? items : items.filter { $0.url.lastPathComponent.localizedCaseInsensitiveContains(query) }
        return found.sorted { a, b in
            if a.isDir != b.isDir { return a.isDir }
            switch sort {
            case .name: return a.url.lastPathComponent.localizedStandardCompare(b.url.lastPathComponent) == .orderedAscending
            case .date: return a.date > b.date
            case .size: return a.size > b.size
            }
        }
    }

    private var freeSpace: String {
        let free = try? docs.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
        return "Frei: " + ByteCountFormatter.string(fromByteCount: free ?? 0, countStyle: .file)
    }

    var body: some View {
        List {
            ForEach(shown) { row($0) }
                .onDelete { idx in
                    let rows = shown
                    idx.forEach { try? FileManager.default.removeItem(at: rows[$0].url) }
                    load()
                }
        }
        .searchable(text: $query, prompt: "Suchen")
        .overlay {
            if items.isEmpty {
                Text("Leer.\nMit + Dateien holen oder in einer anderen App „Öffnen mit Entpacker“ wählen.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary).padding()
            }
            if busy {
                VStack {
                    if let progress { ProgressView("Entpacke … \(Int(progress * 100)) %", value: progress) } else { ProgressView("Arbeite …") }
                }
                .frame(width: 220).padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .navigationTitle(dir == docs ? "Entpacker" : dir.lastPathComponent)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if editing {
                    Button("Fertig") { stopEditing() }
                } else {
                    Button { FilePicker.shared.present { fs.receive($0) } } label: { Image(systemName: "plus") }
                    Menu {
                        Button { ask(.folder, "Neuer Ordner", "Name des Ordners", for: [], input: "Neuer Ordner") } label: { Label("Neuer Ordner", systemImage: "folder.badge.plus") }
                        Button { editing = true } label: { Label("Auswählen", systemImage: "checkmark.circle") }
                        Picker("Sortieren", selection: $sort) { ForEach(SortKey.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                        Toggle("Archiv nach dem Entpacken löschen", isOn: $deleteAfter)
                        Section(freeSpace) {}
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            ToolbarItemGroup(placement: .bottomBar) {
                if editing {
                    Button { extract(selection.filter(isArchive)) } label: { Image(systemName: "arrow.down.doc") }
                    Button { zipDialog(Array(selection)) } label: { Image(systemName: "doc.zipper") }
                    Button { moving = MoveJob(urls: Array(selection)) } label: { Image(systemName: "folder") }
                    ShareLink(items: selection.filter { !$0.hasDirectoryPath }) { Image(systemName: "square.and.arrow.up") }
                    Button(role: .destructive) {
                        selection.forEach { try? FileManager.default.removeItem(at: $0) }
                        stopEditing()
                    } label: { Image(systemName: "trash") }
                }
            }
        }
        .quickLookPreview($quick)
        // Jede Präsentation an eine eigene Ansicht hängen: mehrere Dialoge an derselben Ansicht blockieren sich in SwiftUI gegenseitig.
        .background(Color.clear.fullScreenCover(item: $video) { PlayerScreen(url: $0, playlist: items.map(\.url).filter(Kind.isMedia)) })
        .background(Color.clear.sheet(item: $moving) { job in
            MoveSheet(job: job) { error in
                stopEditing()
                if let error { alert = Hint(title: "Fehler", text: error) }
            }
        })
        .background(Color.clear.alert(alert?.title ?? "", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })) {
            switch alert?.kind ?? .info {
            case .password:
                SecureField("Passwort", text: $password)
                Button("Entpacken") { extract(targets, password: password) }
                Button("Abbrechen", role: .cancel) {}
            case .rename:
                TextField("Name", text: $input)
                Button("Umbenennen") { if let t = targets.first { rename(t, to: input) } }
                Button("Abbrechen", role: .cancel) {}
            case .folder:
                TextField("Name", text: $input)
                Button("Anlegen") { newFolder(input) }
                Button("Abbrechen", role: .cancel) {}
            case .zip:
                TextField("Name", text: $input)
                SecureField("Passwort (optional)", text: $password)
                Button("ZIP erstellen") { makeZip(targets, name: input, password: password) }
                Button("Abbrechen", role: .cancel) {}
            case .info:
                Button("OK", role: .cancel) {}
            }
        } message: { Text(alert?.text ?? "") })
        .onAppear(perform: load)
        .onChange(of: fs.tick) { _ in load() }
        .onChange(of: fs.error) { if let e = $0 { alert = Hint(title: "Fehler", text: e); fs.error = nil } }
    }

    // MARK: Zeilen

    private func isArchive(_ u: URL) -> Bool { Kind.archive.contains(u.pathExtension.lowercased()) }

    @ViewBuilder private func row(_ it: FileRow) -> some View {
        let name = it.url.lastPathComponent
        let archive = isArchive(it.url)
        let content = HStack {
            if editing { Image(systemName: selection.contains(it.url) ? "checkmark.circle.fill" : "circle").foregroundStyle(.tint) }
            Image(systemName: it.isDir ? "folder.fill" : archive ? "archivebox.fill" : Kind.isMedia(it.url) ? "play.rectangle.fill" : "doc.fill")
                .frame(width: 28)
            VStack(alignment: .leading) {
                Text(name).lineLimit(2)
                if !it.isDir { Text(ByteCountFormatter.string(fromByteCount: it.size, countStyle: .file)).font(.caption).foregroundStyle(.secondary) }
            }
        }
        Group {
            if it.isDir && !editing {
                NavigationLink(value: it.url) { content }
            } else {
                Button {
                    if editing { if !selection.insert(it.url).inserted { selection.remove(it.url) } } else { open(it.url) }
                } label: { content }
                    .tint(.primary)
            }
        }
        .contextMenu {
            if archive { Button { extract([it.url]) } label: { Label("Entpacken", systemImage: "arrow.down.doc") } }
            if !it.isDir { Button { video = it.url } label: { Label("Im Player öffnen", systemImage: "play.circle") } }
            Button { ask(.rename, "Umbenennen", "Neuer Name", for: [it.url], input: name) } label: { Label("Umbenennen", systemImage: "pencil") }
            Button { moving = MoveJob(urls: [it.url]) } label: { Label("Verschieben", systemImage: "folder") }
            Button { zipDialog([it.url]) } label: { Label("Als ZIP packen", systemImage: "doc.zipper") }
            if !it.isDir { ShareLink(item: it.url) }
            Button(role: .destructive) {
                try? FileManager.default.removeItem(at: it.url)
                load()
            } label: { Label("Löschen", systemImage: "trash") }
        }
    }

    // MARK: Aktionen

    private func open(_ u: URL) {
        if isArchive(u) { extract([u]) }
        else if Kind.isMedia(u) { video = u }
        else if QLPreviewController.canPreview(u as NSURL) { quick = u }
        else { video = u } // unbekanntes Format: VLC versucht es trotzdem
    }

    private func stopEditing() {
        editing = false
        selection = []
        load()
    }

    private func ask(_ kind: Hint.Kind, _ title: String, _ text: String, for urls: [URL], input: String) {
        targets = urls
        self.input = input
        password = ""
        alert = Hint(title: title, text: text, kind: kind)
    }

    private func zipDialog(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        ask(.zip, "ZIP erstellen", "Ohne Passwort bleibt das Feld leer.", for: urls, input: urls.count == 1 ? urls[0].deletingPathExtension().lastPathComponent : "Archiv")
    }

    private func rename(_ url: URL, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !clean.contains("/") else { alert = Hint(title: "Fehler", text: "Ungültiger Name"); return }
        do { try FileManager.default.moveItem(at: url, to: url.deletingLastPathComponent().appendingPathComponent(clean)) }
        catch { alert = Hint(title: "Fehler", text: describe(error)) }
        load()
    }

    private func newFolder(_ name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !clean.contains("/") else { alert = Hint(title: "Fehler", text: "Ungültiger Name"); return }
        do { try FileManager.default.createDirectory(at: unique(dir.appendingPathComponent(clean)), withIntermediateDirectories: false) }
        catch { alert = Hint(title: "Fehler", text: describe(error)) }
        load()
    }

    struct Outcome {
        var errors: [String] = []
        var needsPassword: URL?
    }

    /// Führt Arbeit im Hintergrund aus und hält das Display wach, sonst sperrt das iPhone mitten drin.
    private func work(_ job: @escaping () -> Outcome) {
        busy = true
        progress = nil
        UIApplication.shared.isIdleTimerDisabled = true
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = job()
            DispatchQueue.main.async {
                busy = false
                UIApplication.shared.isIdleTimerDisabled = false
                stopEditing()
                if let url = outcome.needsPassword {
                    targets = [url]
                    password = ""
                    alert = Hint(title: "Passwort nötig", text: outcome.errors.joined(separator: "
"), kind: .password)
                } else if !outcome.errors.isEmpty {
                    alert = Hint(title: "Fehler", text: outcome.errors.joined(separator: "
"))
                }
            }
        }
    }

    private func extract(_ srcs: [URL], password: String? = nil) {
        guard !srcs.isEmpty else { alert = Hint(title: "Kein Archiv", text: "Es ist kein Archiv ausgewählt."); return }
        let remove = deleteAfter
        work {
            var outcome = Outcome()
            for src in srcs {
                do {
                    _ = try Extract.run(src, password: password) { p in DispatchQueue.main.async { progress = p } }
                    if remove { try? FileManager.default.removeItem(at: src) }
                } catch {
                    if srcs.count == 1, Kind.encryptable.contains(src.pathExtension.lowercased()) {
                        outcome.needsPassword = src
                        outcome.errors = ["\(src.lastPathComponent)
\(describe(error))
Falls das Archiv ein Passwort hat, gib es hier ein."]
                    } else {
                        outcome.errors.append("\(src.lastPathComponent): \(describe(error))")
                    }
                }
            }
            return outcome
        }
    }

    private func makeZip(_ urls: [URL], name: String, password: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !clean.contains("/") else { alert = Hint(title: "Fehler", text: "Ungültiger Name"); return }
        let dest = unique(dir.appendingPathComponent(clean.lowercased().hasSuffix(".zip") ? clean : clean + ".zip"))
        work {
            do { try Extract.zip(urls, to: dest, password: password); return Outcome() }
            catch {
                try? FileManager.default.removeItem(at: dest)
                return Outcome(errors: ["ZIP: \(describe(error))"])
            }
        }
    }

    private func load() {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: .skipsHiddenFiles)) ?? []
        items = urls.map {
            let v = try? $0.resourceValues(forKeys: Set(keys))
            return FileRow(url: $0, isDir: v?.isDirectory == true, size: Int64(v?.fileSize ?? 0), date: v?.contentModificationDate ?? .distantPast)
        }
    }
}
